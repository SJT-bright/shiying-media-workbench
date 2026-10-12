"use strict";
const { spawn } = require("node:child_process"),
  fs = require("node:fs"),
  os = require("node:os"),
  path = require("node:path"),
  crypto = require("node:crypto");
class Runner {
  constructor(command, args = [], env = {}, onEvent = () => {}) {
    this.command = command;
    this.prefix = args;
    this.environment = env;
    this.onEvent = onEvent;
    this.child = null;
    this.cancelFile = null;
    this.token = null;
    this.folder = null;
    this.timer = null;
  }
  run(args, input = null) {
    if (this.child) throw Error("已有任务正在处理");
    this.token = crypto.randomBytes(16).toString("hex");
    this.cancelFile = path.join(
      os.tmpdir(),
      "shiying-cancel-" + this.token + ".signal",
    );
    const at = args.indexOf("--folder");
    this.folder = at >= 0 ? args[at + 1] : null;
    return new Promise((resolve, reject) => {
      let buffer = "",
        terminal = null,
        metadata = null,
        lastError = null,
        count = 0;
      const child = spawn(
        this.command,
        [...this.prefix, ...args, "--cancel-file", this.cancelFile],
        {
          shell: false,
          windowsHide: true,
          env: {
            ...process.env,
            ...this.environment,
            PYTHONUTF8: "1",
            PYTHONIOENCODING: "utf-8",
            SHIYING_JOB_TOKEN: this.token,
          },
          stdio: ["pipe", "pipe", "pipe"],
        },
      );
      this.child = child;
      const finish = () => {
        clearTimeout(this.timer);
        this.timer = null;
        this.child = null;
        try {
          fs.unlinkSync(this.cancelFile);
        } catch {}
        if (this.folder && fs.existsSync(this.folder))
          for (const f of fs.readdirSync(this.folder))
            if (f.startsWith(".shiying-" + this.token + "-")) {
              const target = path.join(this.folder, f);
              if (
                fs.lstatSync(target).isDirectory() &&
                !fs.lstatSync(target).isSymbolicLink()
              )
                fs.rmSync(target, { recursive: true, force: true });
            }
      };
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (data) => {
        buffer += data;
        count += Buffer.byteLength(data);
        if (count > 64 * 1024 * 1024 || buffer.length > 4 * 1024 * 1024) {
          lastError = "任务响应超过限制，已停止";
          this.cancel();
          return;
        }
        let pos;
        while ((pos = buffer.indexOf("\n")) >= 0) {
          const raw = buffer.slice(0, pos);
          buffer = buffer.slice(pos + 1);
          try {
            const e = JSON.parse(raw);
            if (e.event === "metadata") metadata = e;
            if (
              [
                "complete",
                "converted",
                "scan_complete",
                "metrics_complete",
                "articles_complete",
                "cancelled",
              ].includes(e.event)
            )
              terminal = e;
            if (e.event === "error") lastError = e.message || "任务失败";
            this.onEvent(e);
          } catch (error) {
            if (!(error instanceof SyntaxError)) {
              lastError = error.message || "保存失败，已有文件保留";
              this.cancel();
            }
          }
        }
      });
      // Raw exceptions may contain authenticated URLs. They never reach UI or logs.
      child.stderr.resume();
      child.stdin.on("error", () => {});
      child.stdin.end(input === null ? "" : JSON.stringify(input));
      child.once("error", () => {
        lastError = "下载组件无法启动，请重新安装拾影";
      });
      child.once("close", (code) => {
        finish();
        if (code === 130 || terminal?.event === "cancelled")
          reject(Error("任务已取消，已保存的文件保留"));
        else if (code !== 0 || lastError)
          reject(Error(lastError || "任务未正常结束，已有文件保留"));
        else if (!terminal && !metadata)
          reject(Error("任务没有返回可确认的结果"));
        else resolve({ terminal, metadata });
      });
    });
  }
  cancel() {
    if (!this.child) return;
    if (this.timer) return;
    fs.writeFileSync(this.cancelFile, "cancel", { mode: 0o600 });
    this.timer = setTimeout(() => {
      if (this.child) this.child.kill();
    }, 5000);
  }
}
module.exports = { Runner };
