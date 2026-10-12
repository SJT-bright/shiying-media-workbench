"use strict";
const fs = require("node:fs"),
  path = require("node:path"),
  crypto = require("node:crypto"),
  { spawn } = require("node:child_process");
const { nativeImage } = require("electron"),
  core = require("./core.cjs");
class Covers {
  constructor(root, tools) {
    this.root = root;
    this.tools = tools;
    this.pending = new Map();
    this.children = new Set();
    this.active = 0;
    this.waiting = [];
  }
  async limited(fn) {
    if (this.closed) throw Error("封面读取已停止");
    if (this.active >= 2) await new Promise((r) => this.waiting.push(r));
    if (this.closed) throw Error("封面读取已停止");
    this.active++;
    try {
      return await fn();
    } finally {
      this.active--;
      this.waiting.shift()?.();
    }
  }
  async once(key, fn) {
    if (this.pending.has(key)) return this.pending.get(key);
    const job = this.limited(fn).finally(() => this.pending.delete(key));
    this.pending.set(key, job);
    return job;
  }
  async cover(raw) {
    const url = core.approvedCover(raw);
    if (!url) throw Error("没有可用的平台封面");
    const key = crypto.createHash("sha256").update(url).digest("hex");
    return this.once(key, async () => {
      fs.mkdirSync(this.root, { recursive: true });
      const out = path.join(this.root, key + ".png");
      if (fs.existsSync(out)) return out;
      let address = url;
      let response;
      for (let n = 0; n <= 4; n++) {
        response = await fetch(address, {
          redirect: "manual",
          signal: AbortSignal.timeout(20000),
        });
        if ([301, 302, 303, 307, 308].includes(response.status)) {
          const next = core.approvedCover(
            new URL(response.headers.get("location"), address).href,
          );
          if (!next) throw Error("封面来源不受支持");
          address = next;
          continue;
        }
        break;
      }
      if (
        !response?.ok ||
        !response.headers.get("content-type")?.startsWith("image/")
      )
        throw Error("封面暂不可用");
      const chunks = [];
      let bytes = 0;
      for await (const b of response.body) {
        bytes += b.length;
        if (bytes > 32 * 1024 * 1024) throw Error("封面超出限制");
        chunks.push(b);
      }
      const image = nativeImage.createFromBuffer(Buffer.concat(chunks)),
        size = image.getSize();
      if (image.isEmpty() || size.width * size.height > 80_000_000)
        throw Error("封面解码失败");
      const result = image.resize({ width: Math.min(640, size.width) }).toPNG();
      fs.writeFileSync(out, result, { flag: "wx" });
      const files = fs
        .readdirSync(this.root)
        .filter((f) => f.endsWith(".png"))
        .map((f) => ({
          file: path.join(this.root, f),
          stat: fs.statSync(path.join(this.root, f)),
        }))
        .sort((a, b) => a.stat.mtimeMs - b.stat.mtimeMs);
      let total = files.reduce((n, f) => n + f.stat.size, 0);
      while (files.length > 300 || total > 256 * 1024 * 1024) {
        const f = files.shift();
        total -= f.stat.size;
        if (f.file !== out) fs.unlinkSync(f.file);
      }
      return out;
    });
  }
  async thumbnail(file) {
    const key = crypto
      .createHash("sha256")
      .update(file + fs.statSync(file).mtimeMs)
      .digest("hex");
    return this.once("local:" + key, async () => {
      fs.mkdirSync(this.root, { recursive: true });
      const out = path.join(this.root, "local-" + key + ".png");
      if (!fs.existsSync(out))
        await new Promise((resolve, reject) => {
          const child = spawn(
            path.join(
              this.tools(),
              process.platform === "win32" ? "ffmpeg.exe" : "ffmpeg",
            ),
            [
              "-hide_banner",
              "-loglevel",
              "error",
              "-nostdin",
              "-i",
              file,
              "-frames:v",
              "1",
              "-vf",
              "scale=480:-1",
              out,
            ],
            { windowsHide: true, stdio: "ignore" },
          );
          this.children.add(child);
          child.once("error", () => reject(Error("封面组件无法启动")));
          child.once("close", (code) => {
            this.children.delete(child);
            if (code === 0) resolve();
            else {
              try {
                fs.unlinkSync(out);
              } catch {}
              reject(Error("封面读取失败"));
            }
          });
        });
      return out;
    });
  }
  async image(file) {
    const native = nativeImage.createFromPath(file);
    if (!native.isEmpty()) return native;
    return this.limited(
      () =>
        new Promise((resolve, reject) => {
          const child = spawn(
            path.join(
              this.tools(),
              process.platform === "win32" ? "ffmpeg.exe" : "ffmpeg",
            ),
            [
              "-hide_banner",
              "-loglevel",
              "error",
              "-nostdin",
              "-i",
              file,
              "-frames:v",
              "1",
              "-f",
              "image2pipe",
              "-vcodec",
              "png",
              "pipe:1",
            ],
            { windowsHide: true, stdio: ["ignore", "pipe", "ignore"] },
          );
          this.children.add(child);
          let bytes = 0,
            overflow = false;
          const chunks = [];
          child.stdout.on("data", (b) => {
            bytes += b.length;
            if (bytes > 320 * 1024 * 1024) {
              overflow = true;
              child.kill();
            } else chunks.push(b);
          });
          child.once("error", () => reject(Error("图片解码组件无法启动")));
          child.once("close", (code) => {
            this.children.delete(child);
            if (code !== 0 || overflow)
              return reject(Error("图片完整解码失败，原文件保留"));
            const image = nativeImage.createFromBuffer(Buffer.concat(chunks));
            if (image.isEmpty()) reject(Error("图片解码失败"));
            else resolve(image);
          });
        }),
    );
  }
  close() {
    this.closed = true;
    for (const c of this.children) c.kill();
    this.waiting.splice(0).forEach((r) => r());
  }
}
module.exports = { Covers };
