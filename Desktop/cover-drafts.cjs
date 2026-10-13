"use strict";
const fs = require("node:fs"), path = require("node:path"), crypto = require("node:crypto");
const core = require("./core.cjs");
const marker = ".shiying-photo-owner", saveMarker = ".shiying-cover-save-owner";
const hash = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const inside = (file, root) => { const r = path.relative(root, file); return r !== "" && !r.startsWith(".." + path.sep) && r !== ".." && !path.isAbsolute(r); };
function selection(value) {
  const result = { video: value?.video ?? true, cover: value?.cover ?? false };
  if (typeof result.video !== "boolean" || typeof result.cover !== "boolean" || !(result.video || result.cover)) throw Error("请至少选择一项采集内容。");
  return result;
}
class CoverDrafts {
  constructor(dataRoot) {
    this.root = path.join(fs.realpathSync(dataRoot), "cover-previews");
    this.journal = path.join(dataRoot, "cover-save.json");
    fs.mkdirSync(this.root, { recursive: true });
    if (fs.lstatSync(this.root).isSymbolicLink()) throw Error("封面临时根目录无效");
  }
  owned(job) {
    if (path.dirname(job) !== this.root || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(path.basename(job)) || !fs.lstatSync(job).isDirectory() || fs.lstatSync(job).isSymbolicLink() || !fs.lstatSync(path.join(job, marker)).isFile() || fs.lstatSync(path.join(job, marker)).isSymbolicLink() || fs.statSync(path.join(job, marker)).size > 64 || fs.readFileSync(path.join(job, marker), "utf8") !== path.basename(job)) throw Error("封面目录不属于本次任务，未清理：" + job);
  }
  create() {
    const job = path.join(this.root, crypto.randomUUID());
    fs.mkdirSync(job); fs.writeFileSync(path.join(job, marker), path.basename(job), { flag: "wx", mode: 0o600 });
    return job;
  }
  register(job, event, context = {}) {
    this.owned(job);
    if (event?.mediaKind !== "video_cover" || event.imagePaths?.length !== 1 || !/^[0-9a-f]{64}$/i.test(event.imageSHA256 || "")) throw Error("封面响应不完整，未确认保存");
    const image = path.resolve(event.imagePaths[0]);
    if (!inside(image, job) || !inside(fs.realpathSync(image), fs.realpathSync(job)) || fs.lstatSync(image).isSymbolicLink() || !fs.statSync(image).isFile() || fs.statSync(image).size > 64 * 1024 * 1024 || hash(image) !== event.imageSHA256) throw Error("封面原图与校验值不一致，未确认保存");
    const result = { job, event, imagePaths: [image], sha256: event.imageSHA256, ...context };
    core.atomicWrite(path.join(job, "draft.json"), { image, sha256: result.sha256 });
    return result;
  }
  discard(job) {
    if (!fs.existsSync(job)) return;
    this.owned(job);
    const receipt = path.join(job, "draft.json");
    if (fs.existsSync(receipt)) {
      const d = JSON.parse(fs.readFileSync(receipt, "utf8"));
      if (!inside(d.image, job) || (fs.existsSync(d.image) && (fs.lstatSync(d.image).isSymbolicLink() || hash(d.image) !== d.sha256))) throw Error("封面被外部修改，已保留：" + job);
    }
    fs.rmSync(job, { recursive: true });
  }
  rollback(entries) {
    for (const e of entries) {
      if (!fs.existsSync(e.destination)) continue;
      if (fs.lstatSync(e.destination).isSymbolicLink()) throw Error("保存目录被外部修改，已保留：" + e.destination);
      if (fs.readFileSync(path.join(e.destination, saveMarker), "utf8") !== e.id) throw Error("保存目录所有权标记不符，已保留：" + e.destination);
      const names = fs.readdirSync(e.destination);
      if (names.some((n) => n !== e.filename && n !== saveMarker)) throw Error("保存目录包含未知文件，已保留：" + e.destination);
      const file = path.join(e.destination, e.filename);
      if (fs.existsSync(file) && (fs.lstatSync(file).isSymbolicLink() || hash(file) !== e.sha256)) throw Error("保存图片被外部修改，已保留：" + e.destination);
      fs.rmSync(e.destination, { recursive: true });
    }
  }
  recover(library) {
    if (fs.existsSync(this.journal)) {
      if (library.blocked) throw Error("资料库异常，封面恢复记录已保留");
      const j = JSON.parse(fs.readFileSync(this.journal, "utf8"));
      if (j.version !== 1 || !Array.isArray(j.entries)) throw Error("封面保存恢复记录无效，已保留");
      // Only the explicitly created directories from this transaction can be rolled back.
      for (const e of j.entries) {
        if (path.dirname(e.destination) !== j.folder || !/^[0-9a-f-]{36}$/.test(e.id) || path.basename(e.filename) !== e.filename || !/^[0-9a-f]{64}$/.test(e.sha256)) throw Error("封面保存恢复记录无效，已保留");
      }
      const confirmed = j.entries.filter((e) => library.state.records.some((r) => r.id === e.id && r.path === e.destination));
      this.rollback(j.entries.filter((e) => !confirmed.includes(e)));
      for (const e of confirmed) { const f = path.join(e.destination, saveMarker); if (fs.existsSync(f) && fs.readFileSync(f, "utf8") === e.id) fs.unlinkSync(f); }
      fs.unlinkSync(this.journal);
    }
    for (const n of fs.readdirSync(this.root)) {
      const job = path.join(this.root, n);
      if (/^[0-9a-f-]{36}$/i.test(n) && fs.existsSync(path.join(job, marker))) this.discard(job);
    }
  }
  save(drafts, folder, makeRecord, commit) {
    if (!drafts.length) throw Error("没有待保存的封面");
    folder = path.resolve(folder); fs.mkdirSync(folder, { recursive: true });
    if (fs.existsSync(this.journal)) throw Error("上次保存需要恢复，未覆盖记录");
    const entries = [], records = [];
    try {
      for (const d of drafts) {
        this.owned(d.job);
        const image = d.imagePaths[0];
        if (hash(image) !== d.sha256 || fs.lstatSync(image).isSymbolicLink()) throw Error("临时封面被修改，未保存：" + image);
        const stem = core.component((d.event.video?.author || "封面") + "_" + (d.event.video?.title || "作品") + "_封面_" + (d.event.video?.id || ""));
        let dest;
        for (let i = 0; i < 10000; i++) {
          dest = path.join(folder, stem + (i ? "_" + i : ""));
          try { fs.mkdirSync(dest); break; } catch (e) { if (e.code !== "EEXIST") throw e; dest = null; }
        }
        if (!dest) throw Error("同名目录过多");
        const filename = path.basename(image), target = path.join(dest, filename);
        const record = makeRecord(d, { ...d.event, path: dest, imagePaths: [target] });
        fs.writeFileSync(path.join(dest, saveMarker), record.id, { flag: "wx", mode: 0o600 });
        entries.push({ destination: dest, filename, sha256: d.sha256, id: record.id });
        core.atomicWrite(this.journal, { version: 1, folder, entries });
        fs.copyFileSync(image, target, fs.constants.COPYFILE_EXCL);
        if (hash(target) !== d.sha256 || hash(image) !== d.sha256) throw Error("封面复制校验失败");
        records.push(record);
      }
      commit(records);
    } catch (e) {
      this.rollback(entries);
      if (fs.existsSync(this.journal)) fs.unlinkSync(this.journal);
      throw e;
    }
    // A committed transaction is retained if post-commit cleanup is interrupted.
    this.cleanupWarning = null;
    try {
      for (const e of entries) fs.unlinkSync(path.join(e.destination, saveMarker));
      // Keep the committed journal until cleanup has finished. Recovery checks record IDs.
      for (const d of drafts) this.discard(d.job);
      fs.unlinkSync(this.journal);
    } catch (e) { this.cleanupWarning = "封面已经保存；临时清理未完成，请保留文件并重启恢复。" + e.message; }
    return records;
  }
}
module.exports = { CoverDrafts, selection, hash };
