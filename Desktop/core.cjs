"use strict";
const fs = require("node:fs"),
  path = require("node:path"),
  crypto = require("node:crypto");
const platforms = {
  douyin: {
    title: "抖音",
    home: "https://www.douyin.com/",
    domains: ["douyin.com"],
    auth: ["sessionid", "sessionid_ss", "sid_guard"],
  },
  bilibili: {
    title: "B站",
    home: "https://www.bilibili.com/",
    domains: ["bilibili.com", "b23.tv"],
    auth: ["SESSDATA"],
  },
  wechat: {
    title: "视频号",
    home: "https://yuanbao.tencent.com/",
    domains: ["weixin.qq.com", "yuanbao.tencent.com"],
    auth: ["finder_sessionid", "sessionid", "wxuin", "slave_sid"],
  },
  xiaohongshu: {
    title: "小红书",
    home: "https://www.xiaohongshu.com/explore",
    domains: ["xiaohongshu.com", "xhslink.com"],
    auth: ["web_session"],
  },
};
function inDomain(host, root) {
  return host === root || host.endsWith("." + root);
}
function allowedNavigation(raw, platform) {
  try {
    const u = new URL(raw),
      p = platforms[platform];
    return (
      !!p &&
      u.protocol === "https:" &&
      !u.username &&
      !u.password &&
      (!u.port || u.port === "443") &&
      p.domains.some((d) => inDomain(u.hostname, d)) &&
      (platform !== "wechat" ||
        u.hostname === "yuanbao.tencent.com" ||
        inDomain(u.hostname, "weixin.qq.com"))
    );
  } catch {
    return false;
  }
}
function detect(text) {
  for (const raw of String(text).match(/https?:\/\/[^\s<>"\u3000]+/gi) || []) {
    try {
      const u = new URL(raw.replace(/[，。！!；;）)\]}>"'.,]+$/u, ""));
      if (
        u.username ||
        u.password ||
        (u.port && !["80", "443"].includes(u.port))
      )
        continue;
      for (const [name, p] of Object.entries(platforms)) {
        if (name === "wechat" && inDomain(u.hostname, "yuanbao.tencent.com"))
          continue;
        if (
          p.domains.some((d) => inDomain(u.hostname, d)) ||
          (name === "douyin" && inDomain(u.hostname, "iesdouyin.com"))
        )
          return name;
      }
    } catch {}
  }
  return /^\d{19}$/.test(String(text).trim()) ? "douyin" : null;
}
function cookieEnvelope(platform, cookies, now = Date.now() / 1000) {
  const p = platforms[platform];
  if (!p) throw Error("未知平台");
  const rows = [];
  for (const c of cookies) {
    let domain = String(c.domain || "");
    const host = domain.replace(/^\./, "").toLowerCase();
    if (
      platform === "wechat" &&
      host === "tencent.com" &&
      ["hy_user", "hy_token", "hy_source"].includes(c.name)
    )
      domain = "yuanbao.tencent.com";
    else if (!p.domains.some((d) => inDomain(host, d))) continue;
    if (
      (c.expirationDate && c.expirationDate <= now) ||
      typeof c.value !== "string" ||
      typeof c.name !== "string" ||
      /[\r\n\0]/.test(c.value + c.name)
    )
      continue;
    const row = {
      name: c.name,
      value: c.value,
      domain,
      path: c.path || "/",
      secure: c.secure !== false,
      httpOnly: !!c.httpOnly,
    };
    if (c.expirationDate) row.expires = c.expirationDate;
    rows.push(row);
  }
  return platform === "douyin" ? rows : { version: 1, platform, cookies: rows };
}
function hasSession(platform, payload) {
  const rows = Array.isArray(payload) ? payload : payload.cookies || [],
    p = platforms[platform];
  if (platform === "wechat") {
    const names = new Set(
      rows
        .filter(
          (c) =>
            c.domain.replace(/^\./, "") === "yuanbao.tencent.com" && c.value,
        )
        .map((c) => c.name),
    );
    if (names.has("hy_user") && names.has("hy_token")) return true;
  }
  return rows.some((c) => p.auth.includes(c.name) && c.value);
}
function component(value) {
  let s = String(value)
    .replace(/[<>:"/\\|?*\x00-\x1f]/g, "_")
    .replace(/[.\s]+$/g, "")
    .trim();
  if (/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$/i.test(s)) s = "_" + s;
  return s.slice(0, 90) || "未命名";
}
function atomicWrite(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + "." + crypto.randomUUID() + ".tmp";
  try {
    fs.writeFileSync(tmp, JSON.stringify(value, null, 2), {
      flag: "wx",
      mode: 0o600,
    });
    if (fs.existsSync(file)) fs.copyFileSync(file, file + ".backup");
    fs.renameSync(tmp, file);
  } finally {
    if (fs.existsSync(tmp)) fs.unlinkSync(tmp);
  }
}
class Library {
  constructor(root) {
    this.root = root;
    this.file = path.join(root, "library.json");
    this.blocked = null;
    this.state = {
      version: 1,
      records: [],
      collections: [],
      queue: [],
      articles: [],
      statistics: {},
      settings: {
        quality: "highest",
        folder: path.join(
          require("node:os").homedir(),
          "Downloads",
          "拾影资料",
        ),
        theme: "dark",
        articleFolder: null,
      },
    };
    if (fs.existsSync(this.file)) {
      try {
        const d = JSON.parse(fs.readFileSync(this.file, "utf8"));
        if (
          d.version !== 1 ||
          !["records", "collections", "queue", "articles"].every((k) =>
            Array.isArray(d[k]),
          ) ||
          !d.settings ||
          !d.statistics
        )
          throw Error("结构无效");
        this.state = d;
      } catch (e) {
        this.blocked = "资料库无法读取，原文件已保留，请从备份恢复后重启。";
      }
    }
    for (const q of this.state.queue)
      if (q.status === "running") q.status = "pending";
    for (const a of this.state.articles)
      if (a.attemptStatus === "processing" || a.status === "processing") {
        a.attemptStatus = "failed";
        a.error = "上次保存中断，可重新保存；已有文件保留";
        if (!a.htmlPath) a.status = "failed";
      }
  }
  update(mutator) {
    if (this.blocked) throw Error(this.blocked);
    const next = structuredClone(this.state);
    const result = mutator(next);
    atomicWrite(this.file, next);
    this.state = next;
    return result;
  }
  collection(id) {
    const c = this.state.collections.find((c) => c.id === id);
    if (!c) throw Error("收藏夹不存在");
    return c;
  }
  create(name, parentID = null, notes = "", base = null) {
    if (Buffer.byteLength(notes) > 32768) throw Error("备注最多32 KiB");
    const parent = parentID ? this.collection(parentID) : null,
      folder = path.join(
        parent?.path || base || this.state.settings.folder,
        component(name),
      );
    fs.mkdirSync(path.dirname(folder), { recursive: true });
    fs.mkdirSync(folder);
    const c = {
      id: crypto.randomUUID(),
      name: component(name),
      path: folder,
      parentID,
      notes,
      createdAt: new Date().toISOString(),
    };
    try {
      this.update((d) => d.collections.push(c));
    } catch (e) {
      fs.rmdirSync(folder);
      throw e;
    }
    return c;
  }
  move(id, parentID) {
    const c = this.collection(id),
      parent = parentID ? this.collection(parentID) : null;
    if (parentID === id) throw Error("不能移动到自身");
    let p = parent;
    while (p) {
      if (p.id === id) throw Error("不能移动到自己的子文件夹");
      p = p.parentID ? this.collection(p.parentID) : null;
    }
    const dest = path.join(parent?.path || this.state.settings.folder, c.name);
    if (path.resolve(c.path) === path.resolve(dest)) return;
    if (fs.existsSync(dest)) throw Error("目标已有同名文件夹，未覆盖");
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const old = c.path,
      journal = path.join(this.root, "move-journal.json");
    atomicWrite(journal, { id, old, dest, parentID });
    try {
      fs.renameSync(old, dest);
      this.update((d) => {
        const relocate = (s) =>
          s === old
            ? dest
            : typeof s === "string" && s.startsWith(old + path.sep)
              ? dest + s.slice(old.length)
              : s;
        for (const item of [
          ...d.collections,
          ...d.records,
          ...d.queue,
          ...d.articles,
        ]) {
          for (const k of [
            "path",
            "folder",
            "audioPath",
            "htmlPath",
            "coverPath",
            "markdownPath",
          ])
            if (item[k]) item[k] = relocate(item[k]);
          if (item.imagePaths) item.imagePaths = item.imagePaths.map(relocate);
        }
        d.collections.find((x) => x.id === id).parentID = parentID;
      });
      fs.unlinkSync(journal);
    } catch (e) {
      if (fs.existsSync(dest) && !fs.existsSync(old)) {
        try {
          fs.renameSync(dest, old);
        } catch {
          this.blocked = "目录回滚未完成，请保留移动记录并重新启动恢复。";
        }
      }
      if (!this.blocked && fs.existsSync(journal)) fs.unlinkSync(journal);
      throw e;
    }
  }
  recoverMove() {
    const file = path.join(this.root, "move-journal.json");
    if (!fs.existsSync(file)) return;
    try {
      const j = JSON.parse(fs.readFileSync(file)),
        c = this.collection(j.id);
      if (c.path === j.dest && fs.existsSync(j.dest) && !fs.existsSync(j.old))
        fs.unlinkSync(file);
      else if (c.path === j.old) {
        if (fs.existsSync(j.dest) && !fs.existsSync(j.old))
          fs.renameSync(j.dest, j.old);
        if (!fs.existsSync(j.old) || fs.existsSync(j.dest))
          throw Error("位置冲突");
        fs.unlinkSync(file);
      } else throw Error("记录冲突");
    } catch {
      this.blocked = "目录移动恢复失败，已停止写入，请保留move-journal.json。";
    }
  }
  articleEvent(e) {
    if (
      !e.link ||
      !["article_progress", "article_saved", "article_failure"].includes(
        e.event,
      )
    )
      return;
    const old = this.state.articles.find((a) => a.link === e.link);
    if (e.event === "article_progress" && old?.attemptStatus === "processing")
      return;
    return this.update((d) => {
      let a = d.articles.find((a) => a.link === e.link);
      if (!a) {
        a = {
          id: crypto.randomUUID(),
          link: e.link,
          title: "待读取文章",
          date: new Date().toISOString(),
          status: "processing",
        };
        d.articles.unshift(a);
      }
      if (e.event === "article_saved")
        Object.assign(a, e.article, {
          htmlPath: path.join(e.article.path, "文章.html"),
          status: "saved",
          attemptStatus: "saved",
          error: null,
          checkedAt: new Date().toISOString(),
        });
      else if (e.event === "article_failure") {
        a.error = e.message || "文章未能完整保存";
        a.attemptStatus = "failed";
        if (!a.htmlPath) a.status = "failed";
      } else {
        a.attemptStatus = "processing";
        if (!a.htmlPath) a.status = "processing";
      }
    });
  }
  endArticles() {
    if (
      !this.state.articles.some(
        (a) => a.attemptStatus === "processing" || a.status === "processing",
      )
    )
      return;
    this.update((d) => {
      for (const a of d.articles)
        if (a.attemptStatus === "processing" || a.status === "processing") {
          a.attemptStatus = "failed";
          a.error = "上次保存中断，可重新保存；已有文件保留";
          if (!a.htmlPath) a.status = "failed";
        }
    });
  }
  complete(record, queueID = null) {
    return this.update((d) => {
      if (queueID) {
        const q = d.queue.find((q) => q.id === queueID);
        if (!q) throw Error("队列条目不存在，文件已保留");
        Object.assign(q, {
          status: "completed",
          recordID: record.id,
          title: record.title,
          error: null,
        });
        record.creatorSourceURL = q.creatorSourceURL;
        if (q.wantsAudio && !["image_album", "video_cover"].includes(record.mediaKind))
          record.audioError = "音轨尚未完成，可手动重试";
      }
      d.records.unshift(record);
      return record;
    });
  }
  enqueuePosts(
    posts,
    collectionID,
    homepage,
    quality = "highest",
    audio = true,
  ) {
    this.collection(collectionID);
    if (posts.length > 250000) throw Error("单次作品超过上限");
    return this.update((d) => {
      let n = 0;
      for (const p of posts) {
        if (p.isVideo === false || !detect(p.link)) continue;
        if (
          !d.queue.some(
            (q) =>
              q.collectionID === collectionID &&
              (q.videoID === p.id || q.link === p.link),
          ) &&
          !d.records.some(
            (r) => r.collectionID === collectionID && r.videoID === p.id && r.mediaKind !== "video_cover",
          )
        ) {
          d.queue.push({
            id: crypto.randomUUID(),
            link: p.link,
            videoID: p.id,
            creatorSourceURL: homepage,
            metadata: p,
            collectionID,
            quality,
            wantsAudio: audio,
            status: "pending",
            title: p.title || "等待解析",
          });
          n++;
        }
      }
      return n;
    });
  }
  enqueue(text, collectionID, quality = "highest", audio = true) {
    const c = this.collection(collectionID),
      all = String(text)
        .split(/\r?\n/)
        .map((x) => x.trim())
        .filter(Boolean);
    if (Buffer.byteLength(text) > 5 * 1024 * 1024 || all.length > 5000)
      throw Error("最多5000行、5 MiB，超限不会截断");
    const links = all.map((link) => {
      if (!detect(link)) throw Error("包含不支持的平台链接，请修改后导入");
      return link;
    });
    return this.update((d) => {
      let added = 0;
      for (const link of links)
        if (!d.queue.some((q) => q.collectionID === c.id && q.link === link)) {
          d.queue.push({
            id: crypto.randomUUID(),
            link,
            collectionID: c.id,
            quality,
            wantsAudio: audio,
            status: "pending",
            title: "等待解析",
          });
          added++;
        }
      return added;
    });
  }
}
function validDate(value) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || "");
  if (!m || Number(m[1]) < 1970 || Number(m[1]) > 9999) return false;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return (
    d.getUTCFullYear() === Number(m[1]) &&
    d.getUTCMonth() === Number(m[2]) - 1 &&
    d.getUTCDate() === Number(m[3])
  );
}
function filteredPosts(posts, filter) {
  for (const key of ["start", "end"])
    if (filter[key] && !validDate(filter[key]))
      throw Error("请选择有效的年月日");
  if (filter.start && filter.end && filter.start > filter.end)
    throw Error("开始日期不能晚于结束日期");
  for (const key of ["likes", "collects"])
    if (
      filter[key] != null &&
      filter[key] !== "" &&
      (!Number.isFinite(Number(filter[key])) ||
        Number(filter[key]) < 0 ||
        Number(filter[key]) > Number.MAX_SAFE_INTEGER)
    )
      throw Error("互动门槛必须是有效的非负数");
  let list = posts.filter(
    (p) => p.link && p.isVideo !== false && p.mediaKind !== "image_album",
  );
  if (filter.keyword)
    list = list.filter((p) => (p.title || "").includes(filter.keyword));
  for (const [key, f] of [
    ["diggCount", "likes"],
    ["collectCount", "collects"],
  ])
    if (filter[f] !== "" && filter[f] != null)
      list = list.filter(
        (p) => typeof p[key] === "number" && p[key] > Number(filter[f]),
      );
  for (const [f, end] of [
    ["start", false],
    ["end", true],
  ])
    if (filter[f]) {
      const t =
        Date.parse(
          filter[f] + (end ? "T23:59:59.999+08:00" : "T00:00:00+08:00"),
        ) / 1000;
      list = list.filter(
        (p) =>
          typeof (p.createdAt ?? p.publishedAt) === "number" &&
          (end
            ? (p.createdAt ?? p.publishedAt) <= t
            : (p.createdAt ?? p.publishedAt) >= t),
      );
    }
  const key =
    filter.sort === "likes"
      ? "diggCount"
      : filter.sort === "collects"
        ? "collectCount"
        : "createdAt";
  return list.sort(
    (a, b) => (b[key] ?? b.publishedAt ?? -1) - (a[key] ?? a.publishedAt ?? -1),
  );
}
function approvedCover(raw) {
  try {
    const u = new URL(raw);
    if (
      !["https:", "http:"].includes(u.protocol) ||
      u.username ||
      u.password ||
      (u.port && !["80", "443"].includes(u.port))
    )
      return null;
    if (
      ![
        "douyinpic.com",
        "byteimg.com",
        "zjcdn.com",
        "hdslb.com",
        "qpic.cn",
        "qlogo.cn",
      ].some((d) => inDomain(u.hostname, d))
    )
      return null;
    u.protocol = "https:";
    u.port = "";
    u.hash = "";
    return u.href;
  } catch {
    return null;
  }
}
function excerpt(value) {
  const parts = Array.from(
    new Intl.Segmenter("zh", { granularity: "grapheme" }).segment(
      String(value || "")
        .replace(/\s+/g, " ")
        .trim(),
    ),
    (x) => x.segment,
  );
  return parts.slice(0, 50).join("") + (parts.length > 50 ? "..." : "");
}
function cardContent(title, description = "") {
  const tags = [],
    re = /[#＃]([\p{L}\p{N}_][\p{L}\p{N}_.-]*)/gu;
  for (const text of [description, title])
    for (const m of String(text || "").matchAll(re)) {
      const tag = m[1].replace(/[.-]+$/, "");
      if (!tags.some((t) => t.toLowerCase() === tag.toLowerCase()))
        tags.push(tag);
    }
  const clean = (s) =>
    String(s || "")
      .replace(re, "")
      .trim();
  const name = clean(title).replace(/\s+/g, " ") || "未命名作品";
  const lines = clean(description).split("\n");
  if (lines[0]?.trim() === name) lines.shift();
  return {
    title: name,
    description: lines.join("\n").trim(),
    tags: tags.slice(0, 5),
  };
}
function shareURL(text) {
  for (const raw of String(text || "").match(/https?:\/\/[^\s<>"\u3000]+/gi) ||
    []) {
    try {
      const u = new URL(raw.replace(/[，。！!；;）)\]}>"'.,]+$/u, ""));
      if (detect(u.href)) return u.href;
    } catch {}
  }
  return null;
}
function statisticKey(record) {
  const platform = record.platform || detect(record.link),
    vid = String(record.videoID || record.video?.id || "").replace(
      /^(bilibili|wechat):/,
      "",
    );
  let id,
    link = shareURL(record.link);
  if (platform === "douyin" && /^\d{19}$/.test(vid)) {
    id = vid;
    link = "https://www.douyin.com/video/" + vid;
  } else if (
    platform === "bilibili" &&
    /^(BV[A-Za-z0-9]{10}|av\d{1,20})$/.test(vid)
  ) {
    id = "bilibili:" + vid;
    link = "https://www.bilibili.com/video/" + vid;
  } else if (platform === "wechat") {
    const m = link?.match(/\/sph\/([\w-]+)/);
    if (m) id = "wechat:share:" + m[1];
    else if (vid) id = "wechat:object:" + vid;
  }
  return id && link
    ? {
        id,
        platform,
        link,
        videoID: vid,
        homepage: platform === "douyin" ? record.creatorSourceURL : undefined,
      }
    : null;
}
function normalizeStatistics(raw) {
  const value = {
    coverURL: approvedCover(raw.coverURL),
    observedAt: raw.observedAt,
    source: raw.source,
  };
  const mapping = {
    likes: ["likeCount", "like"],
    comments: ["commentCount", "comment"],
    collects: ["collectCount", "collect"],
    views: ["viewCount", "view"],
    recommends: ["recommendCount", "recommend"],
    shares: ["shareCount", "share"],
  };
  for (const [key, [count, display]] of Object.entries(mapping)) {
    const n = raw[count];
    value[key] = Number.isSafeInteger(n) && n >= 0 ? n : null;
    value[key + "Text"] =
      typeof raw.displayCounts?.[display] === "string"
        ? raw.displayCounts[display]
        : null;
  }
  return value;
}
function deltas(before, after) {
  const result = [];
  for (const key of [
    "likes",
    "comments",
    "collects",
    "views",
    "recommends",
    "shares",
  ]) {
    if (
      typeof before?.[key] === "number" &&
      typeof after?.[key] === "number" &&
      after[key] !== before[key]
    )
      result.push({
        key,
        before: before[key],
        after: after[key],
        delta: after[key] - before[key],
      });
  }
  return result;
}
function rangeHeader(value, size) {
  if (!value) return { start: 0, end: size - 1, status: 200 };
  const m = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!m || (!m[1] && !m[2])) return null;
  let start = m[1] ? Number(m[1]) : Math.max(0, size - Number(m[2])),
    end = m[2] && m[1] ? Math.min(Number(m[2]), size - 1) : size - 1;
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(end) ||
    start < 0 ||
    start > end ||
    start >= size
  )
    return null;
  return { start, end, status: 206 };
}
module.exports = {
  platforms,
  inDomain,
  allowedNavigation,
  detect,
  cookieEnvelope,
  hasSession,
  component,
  atomicWrite,
  Library,
  filteredPosts,
  statisticKey,
  normalizeStatistics,
  shareURL,
  deltas,
  rangeHeader,
  validDate,
  approvedCover,
  excerpt,
  cardContent,
};
