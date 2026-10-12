"use strict";
const {
  app,
  BrowserWindow,
  WebContentsView,
  ipcMain,
  session,
  dialog,
  shell,
  protocol,
  clipboard,
  ClipboardItem,
  nativeImage,
} = require("electron");
const fs = require("node:fs"),
  path = require("node:path"),
  os = require("node:os"),
  crypto = require("node:crypto"),
  { spawn } = require("node:child_process"),
  { Readable } = require("node:stream");
const { Covers } = require("./covers.cjs");
const core = require("./core.cjs"),
  { Runner } = require("./runner.cjs");
protocol.registerSchemesAsPrivileged([
  {
    scheme: "shiying-media",
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      stream: true,
      corsEnabled: true,
    },
  },
]);
const test = process.argv.includes("--self-test");
const dataRoot = test
  ? fs.mkdtempSync(path.join(os.tmpdir(), "shiying-desktop-test-"))
  : process.platform === "win32"
    ? path.join(app.getPath("appData"), "拾影")
    : path.join(app.getPath("appData"), "拾影-Windows适配开发");
fs.mkdirSync(dataRoot, { recursive: true });
app.setPath("userData", dataRoot);
app.setName(test ? "拾影 Windows 验收" : "拾影");
if (!app.requestSingleInstanceLock()) app.quit();
const capturedCache = new Map();
let auxiliary = null,
  covers;
let win,
  library,
  runner,
  operation = null,
  queueRunning = false,
  loginView = null,
  loginPlatform = null,
  loginEphemeral = false,
  draft = null,
  progress = null,
  lastMetadata = null;
const profiles = new Map(),
  mediaTokens = new Map();
const root = path.resolve(__dirname, "..");
function tools() {
  return app.isPackaged
    ? path.join(process.resourcesPath, "Tools")
    : process.env.POCKET_TOOLS ||
        (process.platform === "win32"
          ? path.join(__dirname, "resources", "Tools")
          : "/opt/homebrew/bin");
}
function worker() {
  return app.isPackaged
    ? [
        path.join(
          process.resourcesPath,
          "worker",
          process.platform === "win32" ? "拾影Worker.exe" : "拾影Worker",
        ),
        [],
      ]
    : [
        process.env.SHIYING_PYTHON ||
          path.join(
            root,
            ".venv",
            process.platform === "win32" ? "Scripts/python.exe" : "bin/python",
          ),
        [path.join(root, "Backend", "worker.py")],
      ];
}
function notify(type, extra = {}) {
  if (win && !win.isDestroyed())
    win.webContents.send("shiying:event", { type, ...extra });
}
function profile(platform) {
  if (!core.platforms[platform]) throw Error("未知平台");
  if (!profiles.has(platform)) {
    const s = session.fromPartition("persist:shiying-" + platform);
    s.setPermissionRequestHandler((_wc, _permission, callback) =>
      callback(false),
    );
    s.on("will-download", (event) => event.preventDefault());
    profiles.set(platform, s);
  }
  return profiles.get(platform);
}
async function savedSession(platform) {
  const data = core.cookieEnvelope(
    platform,
    await profile(platform).cookies.get({}),
  );
  return !Array.isArray(data) && capturedCache.has(platform)
    ? { ...data, ...capturedCache.get(platform) }
    : data;
}
async function state() {
  const logins = {};
  for (const p of Object.keys(core.platforms))
    logins[p] = core.hasSession(p, await savedSession(p));
  return {
    ...library.state,
    records: library.state.records.map((r) => ({
      ...r,
      available:
        r.mediaKind === "image_album"
          ? (r.imagePaths || []).length > 0 &&
            r.imagePaths.every((p) => fs.existsSync(p))
          : !!r.path && fs.existsSync(r.path),
    })),
    articles: library.state.articles.map((a) => ({
      ...a,
      available: !!a.htmlPath && fs.existsSync(a.htmlPath),
    })),
    blocked: library.blocked,
    busy: !!operation,
    queueRunning,
    progress,
    logins,
    metadata: lastMetadata,
    draft: draft
      ? { metadata: draft.metadata, imagePaths: draft.imagePaths }
      : null,
    version: app.getVersion(),
    platform: process.platform,
  };
}
function changed() {
  notify("state");
}
function begin(label) {
  if (operation) throw Error("已有任务正在处理，请等待或取消");
  operation = { id: crypto.randomUUID(), cancelled: false, label };
  progress = { detail: label, percent: 0 };
  notify("progress", progress);
  changed();
  return operation;
}
function end(op) {
  if (operation === op) {
    operation = null;
    progress = null;
    changed();
  }
}
async function run(args, input, callback = () => {}) {
  if (operation?.cancelled) throw Error("任务已取消");
  const [command, prefix] = worker();
  runner = new Runner(command, prefix, { POCKET_TOOLS: tools() }, (e) => {
    if (e.event === "progress") {
      const weight =
        e.stage === "download"
          ? [8, 55]
          : e.stage === "export"
            ? [63, 32]
            : e.stage === "verify"
              ? [95, 4]
              : [3, 0];
      progress = {
        ...e,
        percent: Math.round(
          weight[0] + Math.min(1, Math.max(0, e.progress || 0)) * weight[1],
        ),
      };
      notify("progress", progress);
    } else if (e.event.endsWith("_progress")) {
      progress = {
        detail: e.detail || "正在处理",
        percent: e.total ? Math.round((100 * (e.done || 0)) / e.total) : null,
      };
      notify("progress", progress);
    }
    if (e.event === "metadata") lastMetadata = e;
    callback(e);
  });
  try {
    return await runner.run(args, input);
  } finally {
    runner = null;
  }
}
function recordFrom(e, link, quality, collectionID = null) {
  const meta = e.video || lastMetadata || {};
  return {
    id: crypto.randomUUID(),
    date: new Date().toISOString(),
    title: meta.title || "视频",
    author: meta.author || "",
    description: meta.description || "",
    videoID: meta.id,
    platform: core.detect(link),
    link,
    quality,
    collectionID,
    path: e.path,
    imagePaths: e.imagePaths || [],
    mediaKind: e.mediaKind || "video",
    width: e.width || 0,
    height: e.height || 0,
    duration: e.duration || 0,
    bytes: e.bytes || 0,
    cover: meta.cover,
    status: "completed",
  };
}
function mediaAllowed(file) {
  if (typeof file !== "string") return false;
  const full = path.resolve(file);
  return (
    [...library.state.records, ...library.state.articles].some((r) =>
      [r.path, r.audioPath, r.htmlPath, r.coverPath, ...(r.imagePaths || [])]
        .filter(Boolean)
        .some((p) => path.resolve(p) === full),
    ) || draft?.imagePaths.some((p) => path.resolve(p) === full)
  );
}
function mediaURL(file, internal = false) {
  if (
    (!internal && !mediaAllowed(file)) ||
    !fs.existsSync(file) ||
    !fs.statSync(file).isFile()
  )
    throw Error("文件不存在或未登记");
  const token = crypto.randomUUID();
  if (mediaTokens.size >= 5000)
    mediaTokens.delete(mediaTokens.keys().next().value);
  mediaTokens.set(token, {
    file: path.resolve(file),
    root: fs.realpathSync(path.dirname(path.resolve(file))),
    assets: library.state.articles.some((a) => a.htmlPath === file),
  });
  return (
    "shiying-media://" + token + "/" + encodeURIComponent(path.basename(file))
  );
}
function configureNavigation(contents, platform) {
  contents.setWindowOpenHandler(({ url }) => {
    if (core.allowedNavigation(url, platform))
      contents.loadURL(url).catch(() => {});
    return { action: "deny" };
  });
  contents.on("will-navigate", (event, url) => {
    if (!core.allowedNavigation(url, platform)) event.preventDefault();
  });
  contents.on("will-redirect", (event, url) => {
    if (!core.allowedNavigation(url, platform)) event.preventDefault();
  });
}
async function closeLogin() {
  if (!loginView) return;
  const view = loginView,
    p = loginPlatform,
    ephemeral = loginEphemeral,
    ownSession = view.webContents.session;
  if (!ephemeral && ["wechat", "xiaohongshu"].includes(p)) {
    try {
      const capture = await view.webContents.executeJavaScript(
        require("./capture.cjs") +
          "; window.__shiyingCapture ? window.__shiyingCapture.read() : null",
      );
      if (
        capture?.capturedPosts?.length &&
        core.allowedNavigation(capture.captureSource, p)
      )
        capturedCache.set(p, capture);
    } catch {}
  }
  loginView = null;
  loginPlatform = null;
  loginEphemeral = false;
  win.contentView.removeChildView(view);
  view.webContents.close();
  if (ephemeral) await ownSession.clearStorageData();
  else {
    await profile(p).flushStorageData();
    await profile(p).cookies.flushStore();
  }
  notify("login-closed");
  changed();
}
function bounds() {
  if (loginView) {
    const [w, h] = win.getContentSize();
    loginView.setBounds({
      x: 224,
      y: 118,
      width: Math.max(240, w - 242),
      height: Math.max(240, h - 134),
    });
  }
}
async function showLogin(platform, url) {
  if (operation) throw Error("请先结束当前任务");
  await closeLogin();
  const address = url || core.platforms[platform]?.home;
  if (!core.allowedNavigation(address, platform))
    throw Error("仅允许当前平台的官方网页");
  loginPlatform = platform;
  loginEphemeral = new URL(address).hostname === "mp.weixin.qq.com";
  const ownSession = loginEphemeral
    ? session.fromPartition("shiying-article-" + crypto.randomUUID())
    : profile(platform);
  if (loginEphemeral) {
    ownSession.setPermissionRequestHandler((_w, _p, done) => done(false));
    ownSession.setPermissionCheckHandler(() => false);
    ownSession.on("will-download", (e) => e.preventDefault());
  }
  loginView = new WebContentsView({
    webPreferences: {
      session: ownSession,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.contentView.addChildView(loginView);
  configureNavigation(loginView.webContents, platform);
  if (!loginEphemeral)
    try {
      loginView.webContents.debugger.attach("1.3");
      await loginView.webContents.debugger.sendCommand("Page.enable");
      await loginView.webContents.debugger.sendCommand(
        "Page.addScriptToEvaluateOnNewDocument",
        { source: require("./capture.cjs") },
      );
    } catch {}
  loginView.webContents.on("did-fail-load", (_e, code, _d) => {
    if (code !== -3)
      notify("message", {
        message: "网页暂未加载成功，可关闭后重新打开；已有登录保留。",
      });
  });
  bounds();
  await loginView.webContents.loadURL(address);
  return true;
}
function resetDraft() {
  if (draft) {
    fs.rmSync(draft.root, { recursive: true, force: true });
    draft = null;
    changed();
  }
}
async function parseSingle(link, platform) {
  resetDraft();
  const folder = fs.mkdtempSync(path.join(dataRoot, "photo-preview-"));
  fs.writeFileSync(
    path.join(folder, "owner.json"),
    JSON.stringify({ kind: "shiying-photo-draft", id: crypto.randomUUID() }),
    { flag: "wx", mode: 0o600 },
  );
  try {
    const payload = await savedSession(platform),
      args = ["info", "--link", link, "--folder", folder, "--preview-images"];
    if (platform !== "douyin") args.push("--session-stdin");
    const result = await run(args, platform === "douyin" ? null : payload);
    if (result.terminal?.mediaKind === "image_album") {
      draft = {
        root: folder,
        link,
        metadata: result.terminal.video || result.metadata,
        imagePaths: result.terminal.imagePaths,
      };
      changed();
      return result.metadata;
    }
    fs.rmSync(folder, { recursive: true, force: true });
    changed();
    return result.metadata;
  } catch (e) {
    fs.rmSync(folder, { recursive: true, force: true });
    throw e;
  }
}
async function saveDraft() {
  if (!draft) throw Error("没有待保存的图文");
  const old = draft,
    folder = library.state.settings.folder;
  fs.mkdirSync(folder, { recursive: true });
  const stem = core.component(
    (old.metadata?.author || "图文") + "_" + (old.metadata?.title || "图片"),
  );
  let dest;
  for (let n = 0; n < 10000; n++) {
    dest = path.join(folder, stem + (n ? "_" + n : ""));
    try {
      fs.mkdirSync(dest);
      break;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      dest = null;
    }
  }
  if (!dest) throw Error("同名目录过多");
  const images = [];
  try {
    for (const p of old.imagePaths) {
      const target = path.join(dest, path.basename(p));
      fs.copyFileSync(p, target, fs.constants.COPYFILE_EXCL);
      if (
        crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex") !==
        crypto
          .createHash("sha256")
          .update(fs.readFileSync(target))
          .digest("hex")
      )
        throw Error("图片复制校验失败");
      images.push(target);
    }
    const r = recordFrom(
      {
        path: dest,
        mediaKind: "image_album",
        imagePaths: images,
        bytes: images.reduce((a, p) => a + fs.statSync(p).size, 0),
        video: old.metadata,
      },
      old.link,
      "highest",
    );
    library.update((d) => d.records.unshift(r));
    resetDraft();
    return r;
  } catch (e) {
    fs.rmSync(dest, { recursive: true, force: true });
    throw e;
  }
}
async function downloadOne(
  link,
  quality,
  folder,
  collectionID = null,
  queueID = null,
) {
  const platform = core.detect(link);
  if (!platform) throw Error("请粘贴支持的平台分享链接");
  fs.mkdirSync(folder, { recursive: true });
  const input = await savedSession(platform),
    args = [
      "download",
      "--link",
      link,
      "--quality",
      quality,
      "--folder",
      folder,
    ];
  if (platform !== "douyin") args.push("--session-stdin");
  const result = await run(args, platform === "douyin" ? null : input);
  if (!result.terminal || result.terminal.event !== "complete")
    throw Error("没有可确认的保存结果");
  const r = recordFrom(result.terminal, link, quality, collectionID);
  library.complete(r, queueID);
  lastMetadata = {
    ...lastMetadata,
    width: r.width,
    height: r.height,
    duration: r.duration,
    size: r.bytes,
  };
  changed();
  return r;
}
async function audioFor(r) {
  if (r.mediaKind === "image_album") return;
  const name = path.basename(r.path, path.extname(r.path));
  let output;
  for (let i = 0; i < 10000; i++) {
    const candidate = path.join(
      path.dirname(r.path),
      name + (i ? "_" + i : "") + ".m4a",
    );
    try {
      const fd = fs.openSync(candidate, "wx");
      fs.closeSync(fd);
      output = candidate;
      break;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
    }
  }
  if (!output) throw Error("同名音频过多");
  const temporary = output + "." + crypto.randomUUID() + ".m4a";
  try {
    await new Promise((resolve, reject) => {
      const child = spawn(
        path.join(
          tools(),
          process.platform === "win32" ? "ffmpeg.exe" : "ffmpeg",
        ),
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-nostdin",
          "-i",
          r.path,
          "-vn",
          "-c:a",
          "aac",
          "-b:a",
          "160k",
          temporary,
        ],
        { windowsHide: true, stdio: "ignore" },
      );
      auxiliary = child;
      child.once("error", () => reject(Error("音频组件无法启动")));
      child.once("close", (code) => {
        if (auxiliary === child) auxiliary = null;
        code === 0 ? resolve() : reject(Error("音频提取失败，原视频保留"));
      });
    });
    fs.renameSync(temporary, output);
    library.update((d) => {
      const record = d.records.find((x) => x.id === r.id);
      if (!record) throw Error("记录已移除，音轨文件保留");
      record.audioPath = output;
      record.audioError = null;
    });
  } catch (e) {
    for (const p of [temporary, output])
      try {
        fs.unlinkSync(p);
      } catch {}
    throw e;
  }
}
async function startQueue() {
  const op = begin("正在处理批量队列");
  queueRunning = true;
  changed();
  try {
    for (;;) {
      if (op.cancelled) break;
      const q = library.state.queue.find((q) => q.status === "pending");
      if (!q) break;
      library.update(
        (d) => (d.queue.find((x) => x.id === q.id).status = "running"),
      );
      changed();
      try {
        const c = library.collection(q.collectionID),
          r = await downloadOne(q.link, q.quality, c.path, c.id, q.id);
        library.update((d) => {
          const saved = d.records.find((x) => x.id === r.id);
          saved.creatorSourceURL = q.creatorSourceURL;
        });
        if (q.wantsAudio)
          try {
            await audioFor(r);
          } catch (e) {
            library.update(
              (d) =>
                (d.records.find((x) => x.id === r.id).audioError = e.message),
            );
          }
        library.update((d) =>
          Object.assign(
            d.queue.find((x) => x.id === q.id),
            { status: "completed", recordID: r.id, title: r.title },
          ),
        );
      } catch (e) {
        library.update((d) =>
          Object.assign(
            d.queue.find((x) => x.id === q.id),
            { status: op.cancelled ? "pending" : "failed", error: e.message },
          ),
        );
      }
      changed();
    }
  } finally {
    queueRunning = false;
    end(op);
  }
  return true;
}
function articleEvent(e) {
  library.articleEvent(e);
  if (e.event === "article_failure") notify("message", { message: e.message });
  if (
    ["article_progress", "article_saved", "article_failure"].includes(e.event)
  )
    changed();
}
async function captureArticle() {
  if (!loginView || loginPlatform !== "wechat")
    throw Error("请打开文章内置网页");
  const link = loginView.webContents.getURL();
  if (!link.startsWith("https://mp.weixin.qq.com/"))
    throw Error("当前不是公众号文章页");
  const snap = await loginView.webContents.executeJavaScript(
    `(()=>{const body=document.querySelector('#js_content');if(!body)return null;const text=s=>document.querySelector(s)?.textContent?.trim()||'';return{html:body.outerHTML,title:text('#activity-name'),account:text('#js_name'),author:text('#js_author_name'),published:text('#publish_time'),coverURL:document.querySelector('meta[property="og:image"]')?.content||''};})()`,
  );
  if (!snap || Buffer.byteLength(snap.html) > 2 * 1024 * 1024)
    throw Error("文章尚未完整加载或超过上限，请在网页完成验证");
  await closeLogin();
  const op = begin("正在保存当前文章");
  try {
    const folder =
      library.state.settings.articleFolder || library.state.settings.folder;
    fs.mkdirSync(folder, { recursive: true });
    return await run(
      ["articles", "--folder", folder],
      { links: [link], snapshots: { [link]: snap } },
      articleEvent,
    );
  } finally {
    try {
      library.endArticles();
    } finally {
      end(op);
    }
  }
}
async function task(value) {
  await closeLogin();
  const op = begin("正在处理");
  try {
    const { kind, link } = value || {};
    if (kind === "info") return await parseSingle(link, core.detect(link));
    if (kind === "download") {
      const meta = await parseSingle(link, core.detect(link));
      if (draft) return { draft: true };
      if (op.cancelled) throw Error("任务已取消");
      return await downloadOne(
        link,
        library.state.settings.quality,
        library.state.settings.folder,
      );
    }
    if (kind === "scan") {
      const p = value.platform;
      if (!p || !link) throw Error("请输入当前平台博主主页或分享");
      const previous = value.resume ? library.state.scanState : null;
      if (
        value.resume &&
        (!previous || previous.link !== link || previous.platform !== p)
      )
        throw Error("继续采集必须使用原来的博主主页");
      const input = await savedSession(p),
        args = ["scan", "--link", link, "--platform", p, "--session-stdin"],
        posts = previous?.posts?.slice() || [];
      let completed = null,
        creator = previous?.creator || null,
        seenPath = null;
      if (previous?.result?.cursor) {
        args.push("--resume-cursor", previous.result.cursor);
        if (!previous.result.complete) args.push("--prior-partial");
        seenPath = path.join(
          os.tmpdir(),
          "shiying-seen-" + crypto.randomUUID() + ".json",
        );
        core.atomicWrite(
          seenPath,
          p === "douyin"
            ? {
                version: 2,
                ids: posts.map((x) => x.id),
                coauthoredIDs: posts
                  .filter((x) => x.isCoauthored === true)
                  .map((x) => x.id),
              }
            : posts.map((x) => x.id),
        );
        args.push("--seen-ids-file", seenPath);
      }
      try {
        await run(args, input, (e) => {
          if (e.event === "creator") creator = e;
          if (e.event === "post") {
            const row = e.post || e;
            if (!posts.some((x) => x.id === row.id)) {
              posts.push(row);
              notify("scan-post", { post: row });
            }
          }
          if (e.event === "scan_complete") completed = e;
        });
      } finally {
        if (seenPath)
          try {
            fs.unlinkSync(seenPath);
          } catch {}
        library.update((d) => {
          d.scanState = {
            platform: p,
            link,
            posts,
            creator,
            result: completed || { complete: false, reason: "interrupted" },
          };
          for (const post of posts)
            if (post.statistics && d.records.some((r) => r.videoID === post.id))
              d.statistics[post.id] = core.normalizeStatistics(post.statistics);
        });
      }
      return { posts, result: completed, creator };
    }
    if (kind === "articles") {
      const links =
        String(value.text || "").match(/https?:\/\/[^\s<>"\u3000]+/gi) || [];
      if (!links.length || links.length > 200)
        throw Error("请提供1至200篇公众号文章链接");
      const folder =
        library.state.settings.articleFolder || library.state.settings.folder;
      fs.mkdirSync(folder, { recursive: true });
      try {
        return await run(
          ["articles", "--folder", folder, "--article-action", "download"],
          { links, snapshots: {} },
          articleEvent,
        );
      } finally {
        library.endArticles();
      }
    }
    if (kind === "metrics") {
      const records = value.ids
        ? library.state.records.filter((r) => value.ids.includes(r.id))
        : library.state.records;
      const works = [
        ...new Map(
          records
            .map(core.statisticKey)
            .filter(Boolean)
            .map((w) => [w.id, w]),
        ).values(),
      ];
      if (!works.length) throw Error("当前没有可更新的作品");
      const sessions = {};
      for (const p of new Set(works.map((w) => w.platform)))
        sessions[p] = await savedSession(p);
      const changes = [],
        failures = [];
      await run(["metrics"], { version: 2, works, sessions }, (e) => {
        if (e.event === "metrics_value") {
          const old = library.state.statistics[e.id];
          const change = {
            id: e.id,
            title:
              records.find((r) => core.statisticKey(r)?.id === e.id)?.title ||
              e.id,
            changes: core.deltas(old, core.normalizeStatistics(e.statistics)),
          };
          library.update(
            (d) =>
              (d.statistics[e.id] = core.normalizeStatistics(e.statistics)),
          );
          if (change.changes.length) changes.push(change);
        }
        if (e.event === "metrics_failure")
          failures.push({ id: e.id, message: e.message });
      });
      notify("statistics-changes", {
        changes,
        failures,
        processed: works.length,
      });
      return { changes, failures };
    }
    throw Error("未知任务");
  } finally {
    end(op);
  }
}
function bind(name, handler) {
  ipcMain.handle("shiying:" + name, async (event, payload) => {
    if (
      event.sender !== win.webContents ||
      event.senderFrame !== win.webContents.mainFrame
    )
      throw Error("拒绝非主界面操作");
    try {
      return await handler(payload);
    } catch (e) {
      if (!["cover", "thumbnail"].includes(name))
        notify("message", { message: e.message || "操作失败" });
      throw Error(e.message || "操作失败");
    }
  });
}
function handlers() {
  bind("state", state);
  bind("paste", () => clipboard.readText());
  bind("settings", (value) => {
    if (operation && (value.folder || value.quality))
      throw Error("处理中不能修改保存设置");
    library.update((d) => {
      if (value.quality && ["480", "720", "highest"].includes(value.quality))
        d.settings.quality = value.quality;
      if (["light", "dark"].includes(value.theme))
        d.settings.theme = value.theme;
      if (value.folder) {
        if (
          !fs.existsSync(value.folder) ||
          !fs.statSync(value.folder).isDirectory()
        )
          throw Error("目录不存在");
        fs.accessSync(value.folder, fs.constants.W_OK);
        d.settings[value.article ? "articleFolder" : "folder"] = path.resolve(
          value.folder,
        );
      }
    });
    changed();
  });
  bind("choose-folder", async () => {
    const r = await dialog.showOpenDialog(win, {
      title: "选择保存位置",
      properties: ["openDirectory", "createDirectory"],
    });
    if (r.canceled) return null;
    library.update((d) => (d.settings.folder = r.filePaths[0]));
    changed();
    return r.filePaths[0];
  });
  bind("folder-list", (value) => {
    let dir = path.resolve(value?.path || library.state.settings.folder);
    if (value?.fallback)
      while (!fs.existsSync(dir) && path.dirname(dir) !== dir)
        dir = path.dirname(dir);
    if (!fs.existsSync(dir)) throw Error("目录不存在，可返回上一级创建");
    return {
      collections: library.state.collections.map((c) => ({
        name: c.name,
        path: c.path,
      })),
      path: dir,
      parent: path.dirname(dir),
      folders: fs
        .readdirSync(dir, { withFileTypes: true })
        .filter((x) => x.isDirectory() && !x.name.startsWith("."))
        .map((x) => ({ name: x.name, path: path.join(dir, x.name) })),
    };
  });
  bind("folder-create", (v) => {
    const dir = path.join(v.parent, core.component(v.name));
    fs.mkdirSync(dir);
    return dir;
  });
  bind("import-text", async () => {
    const r = await dialog.showOpenDialog(win, {
      title: "导入分享文本",
      properties: ["openFile"],
      filters: [{ name: "文本与CSV", extensions: ["txt", "csv"] }],
    });
    if (r.canceled) return null;
    if (fs.statSync(r.filePaths[0]).size > 5 * 1024 * 1024)
      throw Error("文件超过5 MiB");
    return fs.readFileSync(r.filePaths[0], "utf8");
  });
  bind("login", (v) => showLogin(v.platform, v.url));
  bind("login-close", closeLogin);
  bind("login-clear", async (v) => {
    if (operation) throw Error("请先结束当前任务");
    await closeLogin();
    capturedCache.delete(v.platform);
    await profile(v.platform).clearStorageData();
    await profile(v.platform).cookies.flushStore();
    changed();
  });
  bind("filter-posts", (v) => core.filteredPosts(v.posts, v.filter));
  bind("card-content", (v) => core.cardContent(v.title, v.description));
  bind("enqueue-posts", (v) => {
    const n = library.enqueuePosts(
      v.posts,
      v.collectionID,
      library.state.scanState?.creator?.homepage || v.homepage,
      library.state.settings.quality,
    );
    changed();
    return n;
  });
  bind("article-capture", captureArticle);
  bind("task", task);
  bind("cancel", () => {
    if (operation) operation.cancelled = true;
    runner?.cancel();
    auxiliary?.kill();
  });
  bind("photo-save", saveDraft);
  bind("photo-cancel", resetDraft);
  bind("photo-copy", async (v) => {
    if (!draft?.imagePaths.includes(v.path) && !mediaAllowed(v.path))
      throw Error("图片未登记");
    const image = await covers.image(v.path);
    if (image.isEmpty()) throw Error("图片解码失败");
    await clipboard.write([
      new ClipboardItem({
        "image/png": new Blob([image.toPNG()], { type: "image/png" }),
      }),
    ]);
    return true;
  });
  bind("collection-create", (v) => {
    const c = library.create(v.name, v.parentID, v.notes);
    changed();
    return c;
  });
  bind("collection-notes", (v) => {
    if (Buffer.byteLength(v.notes) > 32768) throw Error("备注超过32 KiB");
    library.update(
      (d) => (d.collections.find((c) => c.id === v.id).notes = v.notes),
    );
    changed();
  });
  bind("collection-move", (v) => {
    if (operation) throw Error("任务处理中不能移动资料");
    library.move(v.id, v.parentID);
    changed();
  });
  bind("collection-reorder", (v) => {
    library.update((d) => {
      const a = d.collections.find((c) => c.id === v.id),
        b = d.collections.find((c) => c.id === v.beforeID);
      if (!a || !b || a.parentID !== b.parentID)
        throw Error("只能调整同层顺序");
      d.collections.splice(d.collections.indexOf(a), 1);
      d.collections.splice(d.collections.indexOf(b), 0, a);
    });
    changed();
  });
  bind("enqueue", (v) => {
    const n = library.enqueue(
      v.text,
      v.collectionID,
      v.quality || library.state.settings.quality,
      v.audio !== false,
    );
    changed();
    return n;
  });
  bind("queue-start", startQueue);
  bind("queue-stop", () => {
    if (operation) operation.cancelled = true;
    runner?.cancel();
    auxiliary?.kill();
  });
  bind("queue-retry", (v) => {
    library.update((d) => {
      const q = d.queue.find((x) => x.id === v.id);
      if (q?.status === "failed") q.status = "pending";
    });
    changed();
  });
  bind("queue-audio-retry", async (v) => {
    const r = library.state.records.find((x) => x.id === v.id);
    const op = begin("正在重新提取音频");
    try {
      await audioFor(r);
    } finally {
      end(op);
    }
  });
  bind("remove", (v) => {
    if (operation) throw Error("请先结束当前任务，再移除记录");
    library.update((d) => {
      const list = v.kind === "article" ? d.articles : d.records;
      const i = list.findIndex((r) => r.id === v.id);
      if (i >= 0) list.splice(i, 1);
    });
    changed();
  });
  bind("reveal", (v) => {
    if (
      !mediaAllowed(v.path) &&
      !library.state.collections.some((c) => c.path === v.path)
    )
      throw Error("文件未登记");
    shell.showItemInFolder(v.path);
  });
  bind("open", (v) => {
    if (
      !mediaAllowed(v.path) &&
      !library.state.collections.some((c) => c.path === v.path)
    )
      throw Error("文件未登记");
    return shell.openPath(v.path);
  });
  bind("media", (v) => mediaURL(v.path));
  bind("cover", async (v) => mediaURL(await covers.cover(v.url), true));
  bind("thumbnail", async (v) => {
    if (
      !mediaAllowed(v.path) ||
      !fs.existsSync(v.path) ||
      !fs.statSync(v.path).isFile()
    )
      throw Error("原视频不存在");
    return mediaURL(await covers.thumbnail(v.path), true);
  });
}
async function createWindow() {
  library = new core.Library(dataRoot);
  library.recoverMove();
  covers = new Covers(path.join(dataRoot, "cover-v3"), tools);
  for (const name of fs.readdirSync(dataRoot))
    if (name.startsWith("photo-preview-")) {
      try {
        const folder = path.join(dataRoot, name),
          m = JSON.parse(fs.readFileSync(path.join(folder, "owner.json")));
        if (
          m.kind === "shiying-photo-draft" &&
          /^[0-9a-f-]{36}$/.test(m.id) &&
          !fs.lstatSync(folder).isSymbolicLink()
        )
          fs.rmSync(folder, { recursive: true, force: true });
      } catch {}
    }
  protocol.handle("shiying-media", async (request) => {
    try {
      const u = new URL(request.url),
        entry = mediaTokens.get(u.hostname);
      if (!entry) return new Response("Not found", { status: 404 });
      const file = fs.realpathSync(
        path.resolve(entry.root, decodeURIComponent(u.pathname).slice(1)),
      );
      if (
        (!entry.assets && file !== fs.realpathSync(entry.file)) ||
        !file.startsWith(entry.root + path.sep) ||
        !fs.existsSync(file) ||
        !fs.statSync(file).isFile()
      )
        return new Response("Not found", { status: 404 });
      const stat = fs.statSync(file),
        r = core.rangeHeader(request.headers.get("range"), stat.size);
      if (!r)
        return new Response("", {
          status: 416,
          headers: { "Content-Range": "bytes */" + stat.size },
        });
      const mime = {
        ".mp4": "video/mp4",
        ".m4a": "audio/mp4",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
        ".gif": "image/gif",
        ".html": "text/html; charset=utf-8",
        ".md": "text/plain; charset=utf-8",
      }[path.extname(file).toLowerCase()];
      if (!mime) return new Response("Unsupported", { status: 403 });
      const headers = {
        "Content-Security-Policy":
          "default-src 'none'; img-src shiying-media:; style-src 'unsafe-inline'; base-uri 'none';",
        "Content-Type": mime,
        "Content-Length": String(r.end - r.start + 1),
        "Accept-Ranges": "bytes",
        "Cache-Control": "no-store",
      };
      if (r.status === 206)
        headers["Content-Range"] = `bytes ${r.start}-${r.end}/${stat.size}`;
      return new Response(
        Readable.toWeb(
          fs.createReadStream(file, { start: r.start, end: r.end }),
        ),
        { status: r.status, headers },
      );
    } catch {
      return new Response("Not found", { status: 404 });
    }
  });
  win = new BrowserWindow({
    width: 1280,
    height: 900,
    minWidth: 960,
    minHeight: 700,
    title: test ? "拾影 Windows 验收（隔离）" : "拾影",
    backgroundColor: "#071020",
    show: !test || process.argv.includes("--self-test-keep-open"),
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: !test,
    },
  });
  win.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  win.webContents.on("will-navigate", (event) => event.preventDefault());
  win.on("resize", bounds);
  win.on("closed", () => {
    resetDraft();
    win = null;
  });
  if (test)
    win.webContents.on("console-message", (_e, ...values) =>
      console.log("RENDERER", ...values),
    );
  handlers();
  await win.loadFile(path.join(__dirname, "ui", "index.html"));
  if (test)
    await require("./self-test.cjs").selfTest({
      app,
      win,
      library,
      profile,
      tools,
      worker,
      run,
      state,
      dataRoot,
      mediaURL,
    });
}
app.on("second-instance", () => {
  if (win) {
    win.show();
    win.focus();
  }
});
app.on("before-quit", () => {
  if (operation) operation.cancelled = true;
  runner?.cancel();
  auxiliary?.kill();
  covers?.close();
  resetDraft();
});
app.on("window-all-closed", () => app.quit());
app
  .whenReady()
  .then(createWindow)
  .catch((error) => {
    if (test) console.error(error);
    else
      dialog.showErrorBox("拾影启动失败", "请重新安装应用，现有资料会保留。");
    app.exit(1);
  });
