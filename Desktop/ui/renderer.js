"use strict";
const $ = (id) => document.getElementById(id),
  api = window.shiying;
let model = null,
  page = "single",
  parentID = null,
  posts = [],
  selected = new Set(),
  playing = null,
  photos = [],
  photoIndex = 0,
  browse = null,
  renderSequence = 0;
let browseArticle = false,
  moveID = null,
  visibleLimit = 60,
  renderTimer = null;
const names = {
    douyin: "抖音",
    wechat: "视频号",
    bilibili: "B站",
    xiaohongshu: "小红书",
  },
  metrics = {
    likes: "点赞",
    recommends: "推荐",
    comments: "评论",
    collects: "收藏",
    views: "浏览",
    shares: "转发",
  };
const escape = (s) =>
  String(s ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const fmt = (n) =>
  typeof n === "number"
    ? n.toLocaleString("zh-CN")
    : typeof n === "string"
      ? n
      : "未公开";
const titleMap = {
  single: "新建下载",
  creator: "博主采集",
  queue: "批量收集",
  folders: "收集文件夹",
  records: "下载记录",
  articles: "公众号采集",
  about: "使用说明",
};
function message(text) {
  $("toast").textContent = text;
  $("toast").hidden = false;
  clearTimeout(message.timer);
  message.timer = setTimeout(() => ($("toast").hidden = true), 6500);
}
async function askText(label, initial = "") {
  return new Promise((resolve) => {
    $("textLabel").textContent = label;
    $("textValue").value = initial;
    $("textDialog").showModal();
    $("textValue").focus();
    let accepted = false;
    $("textAccept").onclick = () => {
      accepted = true;
      $("textDialog").close();
    };
    $("textCancel").onclick = () => $("textDialog").close();
    $("textDialog").onclose = () =>
      resolve(accepted ? $("textValue").value : null);
  });
}
async function call(name, payload) {
  try {
    return await api.call(name, payload);
  } catch (e) {
    message(
      e.message.replace(/^Error invoking remote method '[^']+': Error: /, ""),
    );
    throw e;
  }
}
function listener(id, fn, event = "click") {
  $(id).addEventListener(event, () => Promise.resolve(fn()).catch(() => {}));
}
function stopPlayer() {
  document.querySelectorAll("video").forEach((v) => {
    v.pause();
    v.removeAttribute("src");
    v.load();
    v.remove();
  });
  playing = null;
}
async function navigate(next) {
  if (model?.busy && next !== page) {
    message("任务处理中，请等待完成或取消");
    return;
  }
  if (page === "single" && next !== "single" && model?.draft)
    await call("photo-cancel");
  await call("login-close");
  stopPlayer();
  page = next;
  visibleLimit = 60;
  document.querySelector("main").scrollTop = 0;
  for (const button of document.querySelectorAll("nav button"))
    button.classList.toggle("active", button.dataset.page === next);
  for (const section of document.querySelectorAll(".page"))
    section.hidden = section.id !== next;
  $("pageTitle").textContent = titleMap[next];
  $("pageIcon").textContent = {
    single: "＋",
    creator: "▤",
    articles: "▧",
    folders: "▱",
    records: "◷",
    queue: "⇣",
    about: "ⓘ",
  }[next];
  await refresh();
}
async function refresh() {
  model = await call("state");
  document.body.classList.toggle("light", model.settings.theme === "light");
  $("version").textContent = "拾影 " + model.version + " · Windows 适配";
  $("savedCount").textContent = "本地收藏 " + model.records.length + " 个作品";
  $("blocked").hidden = !model.blocked;
  $("blocked").textContent = model.blocked || "";
  $("headerSaved").textContent =
    page === "articles" ? model.articles.length : model.records.length;
  $("headerPending").textContent = model.queue.filter((q) =>
    ["pending", "running"].includes(q.status),
  ).length;
  $("headerBusy").textContent = model.busy ? "◇ 处理中" : "◇ 空闲";
  $("creatorClear").disabled = model.busy;
  $("status").textContent = model.busy ? "正在处理，请稍候" : "素材保存在本机";
  $("saveFolder").textContent = model.settings.folder;
  document.querySelector(".article-folder").textContent =
    model.settings.articleFolder || model.settings.folder;
  document
    .querySelectorAll("[data-quality]")
    .forEach((b) =>
      b.classList.toggle(
        "selected",
        b.dataset.quality === model.settings.quality,
      ),
    );
  for (const id of [
    "download",
    "preview",
    "scan",
    "startQueue",
    "saveArticles",
    "savePhotos",
    "enqueue",
    "enqueuePosts",
    "import",
    "creatorLogin",
    "newCollection",
  ])
    $(id).disabled = model.busy || !!model.blocked;
  document
    .querySelectorAll(".metrics,.folder-chooser")
    .forEach((b) => (b.disabled = model.busy || !!model.blocked));
  for (const select of document.querySelectorAll(".collection-select")) {
    const previous = select.value;
    select.innerHTML =
      '<option value="">选择收藏夹</option>' +
      model.collections
        .map((c) => `<option value="${c.id}">${escape(c.name)}</option>`)
        .join("");
    if (model.collections.some((c) => c.id === previous))
      select.value = previous;
  }
  $("platformLogins").innerHTML = Object.keys(names)
    .map(
      (p) =>
        `<div class="platform-box"><strong>${names[p]}</strong><small>${model.logins[p] ? "已保留本机登录，执行时验证" : "打开内置网页登录"}${p === "wechat" ? " · 元宝解析" : ""}</small><button data-login="${p}">平台登录</button></div>`,
    )
    .join("");
  $("platformLogins")
    .querySelectorAll("button")
    .forEach((b) => (b.onclick = () => login(b.dataset.login).catch(() => {})));
  renderMetadata();
  await renderDraft();
  if (page === "records") renderRecords($("recordList"), filteredRecords());
  if (page === "folders") renderFolders();
  if (page === "queue") renderQueue();
  if (page === "articles") renderArticles();
  $("resumeScan").disabled =
    model.busy ||
    !model.scanState?.result?.cursor ||
    model.scanState.result.complete;
}
function renderMetadata() {
  const m = model.metadata;
  $("metadata").hidden = !m;
  if (m) {
    const duration =
      m.duration > 0
        ? `${Math.floor(m.duration / 60)}:${String(Math.floor(m.duration) % 60).padStart(2, "0")}`
        : "时长待核验";
    $("metadata").innerHTML =
      `<strong>${escape(m.title)}</strong><span>${escape(m.author)}</span><span>${duration}</span><span>${m.size ? (m.size / 1024 / 1024).toFixed(1) + " MB" : ""}</span>`;
  }
}
async function renderDraft() {
  const d = model.draft;
  $("photoDraft").hidden = !d;
  if (!d) {
    $("draftImages").replaceChildren();
    return;
  }
  $("draftImages").replaceChildren();
  for (const file of d.imagePaths) {
    const image = document.createElement("img");
    image.alt = "临时图文";
    image.src = await call("media", { path: file });
    image.onclick = () => showPhotos(d.imagePaths, d.imagePaths.indexOf(file));
    image.oncontextmenu = (e) => {
      e.preventDefault();
      call("photo-copy", { path: file })
        .then(() => message("图片已复制，可直接粘贴"))
        .catch(() => {});
    };
    $("draftImages").append(image);
  }
}
async function login(platform, url) {
  if (model.busy) throw Error("请先结束当前任务");
  $("loginToolbar").hidden = false;
  $("loginName").textContent = names[platform] + " · 内置网页";
  $("loginDone").textContent = "返回工作台";
  try {
    await call("login", { platform, url });
  } catch (e) {
    $("loginToolbar").hidden = true;
    throw e;
  }
}
async function showPhotos(files, index = 0) {
  photos = files;
  photoIndex = index;
  await updatePhoto();
  $("photoDialog").showModal();
}
async function updatePhoto() {
  if (!photos.length) return;
  $("photoTitle").textContent =
    `图片 ${photoIndex + 1} / ${photos.length} · 右键复制`;
  $("photoLarge").src = await call("media", { path: photos[photoIndex] });
}
function filteredRecords() {
  const source = $("sourceFilter").value,
    query = $("search").value;
  return model.records.filter(
    (r) =>
      (source === "all" || r.platform === source) &&
      (!query || (r.title + r.author).includes(query)),
  );
}
function activeRecords() {
  if (page === "folders") return folderRecords();
  return filteredRecords();
}
function folderRecords() {
  const source = $("folderSource").value,
    query = $("folderSearch").value;
  return model.records.filter(
    (r) =>
      r.collectionID === parentID &&
      (source === "all" || r.platform === source) &&
      (!query || (r.title + r.author).includes(query)),
  );
}
function clippedExcerpt(value) {
  const rows = Array.from(
    new Intl.Segmenter("zh", { granularity: "grapheme" }).segment(
      String(value || "")
        .replace(/\s+/g, " ")
        .trim(),
    ),
    (x) => x.segment,
  );
  return rows.slice(0, 50).join("") + (rows.length > 50 ? "..." : "");
}
function marquee(node) {
  requestAnimationFrame(() => {
    const span = node.firstElementChild,
      extra = span.scrollWidth - node.clientWidth;
    if (extra > 1) {
      node.classList.add("marquee");
      node.style.setProperty("--overflow", -extra + "px");
      node.style.setProperty("--title-time", Math.max(8, extra / 24) + "s");
    }
    node.addEventListener("wheel", () => node.classList.add("manual"), {
      once: true,
    });
  });
}
function renderRecords(container, records) {
  const seq = ++renderSequence;
  stopPlayer();
  container.replaceChildren();
  if (!records.length) {
    container.innerHTML = '<p class="empty">还没有保存到这里的作品。</p>';
    return;
  }
  for (const r of records.slice(0, visibleLimit)) {
    const card = document.createElement("article");
    card.className = "glass record-card";
    card.dataset.record = r.id;
    const key =
      r.platform === "douyin"
        ? r.videoID
        : r.platform === "wechat" && r.link?.match(/\/sph\/([\w-]+)/)
          ? "wechat:share:" + r.link.match(/\/sph\/([\w-]+)/)[1]
          : r.platform === "bilibili"
            ? "bilibili:" + String(r.videoID || "").replace(/^bilibili:/, "")
            : null;
    const stats = model.statistics[key] || {},
      namesFor =
        r.platform === "wechat" ? { ...metrics, likes: "喜欢" } : metrics;
    card.innerHTML = `<div class="tile-top"><div class="record-cover"><img alt="作品封面"><button class="play" aria-label="展开／收回播放">${r.mediaKind === "image_album" ? "▧" : "▶"}</button></div><span class="author">${escape(r.author || "未知作者")}</span></div><div class="record-top"><span class="source-tag">${escape(names[r.platform] || "来源待确认")}</span><button class="reveal" aria-label="在文件夹中显示">▱</button></div><h3 class="horizontal-title"><span>${escape(r.title)}</span></h3><div class="description">${escape(r.description)}</div><div class="tags"></div><div class="stats">${Object.entries(
      namesFor,
    )
      .map(
        ([k, label]) =>
          `<span>${label} <b>${escape(fmt(stats[k] ?? stats[k + "Text"]))}</b></span>`,
      )
      .join(
        "",
      )}</div><div class="record-bottom"><small>${escape(r.date?.slice(0, 10) || "")} · 已保存</small><button class="remove" aria-label="移除记录，保留文件">×</button>${r.audioError ? '<button class="retryAudio">重试音轨</button>' : ""}</div>`;
    call("card-content", { title: r.title, description: r.description })
      .then((c) => {
        if (!card.isConnected) return;
        card.querySelector("h3 span").textContent = c.title;
        card.querySelector(".description").textContent = c.description;
        card.querySelector(".tags").textContent = c.tags
          .map((t) => "#" + t)
          .join("　");
        marquee(card.querySelector("h3"));
      })
      .catch(() => {});
    card.querySelector(".reveal").onclick = () =>
      call("reveal", { path: r.path }).catch(() => {});
    card.querySelector(".remove").onclick = () =>
      call("remove", { id: r.id }).catch(() => {});
    card
      .querySelector(".retryAudio")
      ?.addEventListener("click", () =>
        call("queue-audio-retry", { id: r.id }).catch(() => {}),
      );
    const play = card.querySelector(".play");
    play.onclick = async () => {
      if (r.mediaKind === "image_album") {
        await showPhotos(r.imagePaths);
        return;
      }
      if (playing === r.id) {
        stopPlayer();
        play.textContent = "▶";
        return;
      }
      stopPlayer();
      playing = r.id;
      play.textContent = "■";
      const video = document.createElement("video");
      video.controls = true;
      video.className = "inline-player";
      video.preload = "metadata";
      video.src = await call("media", { path: r.path });
      if (playing !== r.id) return;
      card.append(video);
      video.onerror = () =>
        message("原视频不可用或暂无法解码，已保存文件保留。");
      await video.play().catch(() => {});
    };
    const img = card.querySelector("img");
    let source;
    if (r.mediaKind === "image_album" && r.imagePaths?.[0])
      source = call("media", { path: r.imagePaths[0] });
    else
      source = call("cover", { url: stats.coverURL || r.cover }).catch(() =>
        call("thumbnail", { path: r.path }),
      );
    source
      .then((url) => {
        if (seq === renderSequence) img.src = url;
      })
      .catch(() => {
        img.remove();
        play.disabled = true;
      });
    container.append(card);
  }
  if (records.length > visibleLimit) {
    const more = document.createElement("button");
    more.className = "show-more";
    more.textContent = `显示更多（已显示 ${Math.min(visibleLimit, records.length)} / ${records.length}）`;
    more.onclick = () => {
      visibleLimit += 60;
      renderRecords(container, records);
    };
    container.append(more);
  }
}
function renderFolders() {
  const list = model.collections.filter(
      (c) => (c.parentID || null) === parentID,
    ),
    current = model.collections.find((c) => c.id === parentID);
  $("folderList").replaceChildren();
  $("folderBack").disabled = !parentID;
  $("folderBackBottom").hidden = !parentID;
  const header = $("folderHeading");
  header.hidden = !current;
  if (current) {
    header.innerHTML = `<div class="row between"><h2>▱ ${escape(current.name)}</h2><button class="notes">编辑备注</button></div><p>${escape(current.notes || "尚未添加学习备注")}</p>`;
    header.querySelector("button").onclick = () => editNotes(current);
  }
  for (const c of list) {
    const card = document.createElement("article");
    card.className = "folder-card";
    card.draggable = true;
    card.dataset.folder = c.id;
    card.innerHTML = `<button class="enter folder-main"><div class="folder-symbol">▰</div><h3>${escape(c.name)}</h3><p>${escape(c.notes || "尚未添加学习备注")}</p><small>${model.records.filter((r) => r.collectionID === c.id).length} 个作品</small></button><div class="row"><button class="notes">备注</button><button class="move">移动</button><button class="reorder">向前</button></div>`;
    card.querySelector(".enter").onclick = () => {
      parentID = c.id;
      visibleLimit = 60;
      document.querySelector("main").scrollTop = 0;
      renderFolders();
    };
    card.querySelector(".notes").onclick = () => editNotes(c);
    card.querySelector(".move").onclick = () => moveFolder(c);
    card.querySelector(".reorder").onclick = () => {
      const i = list.findIndex((x) => x.id === c.id);
      if (i > 0)
        call("collection-reorder", {
          id: c.id,
          beforeID: list[i - 1].id,
        }).catch(() => {});
    };
    card.ondragstart = (e) =>
      e.dataTransfer.setData("text/shiying-folder", c.id);
    card.ondragover = (e) => e.preventDefault();
    card.ondrop = (e) => {
      e.preventDefault();
      const id = e.dataTransfer.getData("text/shiying-folder");
      if (id && id !== c.id)
        call("collection-move", { id, parentID: c.id }).catch(() => {});
    };
    $("folderList").append(card);
  }
  renderRecords($("folderRecords"), folderRecords());
}
async function editNotes(c) {
  const notes = await askText(c.name + " · 学习备注", c.notes || "");
  if (notes !== null) await call("collection-notes", { id: c.id, notes });
}
function moveFolder(c) {
  moveID = c.id;
  $("moveTitle").textContent = "移动 " + c.name;
  $("moveTarget").innerHTML =
    '<option value="">全部文件夹（顶层）</option>' +
    model.collections
      .filter((x) => x.id !== c.id)
      .map((x) => `<option value="${x.id}">${escape(x.name)}</option>`)
      .join("");
  $("moveDialog").showModal();
}
function renderQueue() {
  $("queueList").replaceChildren();
  for (const q of model.queue) {
    const item = document.createElement("div");
    item.className = "queue-item";
    item.innerHTML = `<div class="body"><strong>${escape(q.title || "等待解析")}</strong><small>${escape(q.error || q.link)}</small></div><small>${{ pending: "待处理", running: "正在处理", completed: "已完成", failed: "失败" }[q.status]}</small>${q.status === "failed" ? "<button>重试</button>" : ""}`;
    item
      .querySelector("button")
      ?.addEventListener("click", () =>
        call("queue-retry", { id: q.id }).catch(() => {}),
      );
    $("queueList").append(item);
  }
}
function renderArticles() {
  $("articleList").replaceChildren();
  for (const a of model.articles) {
    const tile = document.createElement("article");
    tile.className = "glass article-tile";
    tile.innerHTML = `<div class="tile-top"><button class="record-cover article-cover" aria-label="打开文章正文"><img alt="公众号封面"><span class="play">▶</span></button><div class="author">${escape(a.account || a.author || "公众号")}<small>${escape(a.author && a.author !== a.account ? a.author : "")}</small></div></div><div class="record-top"><span class="source-tag">公众号</span><button class="reveal" aria-label="显示文章文件夹">▱</button></div><h3 class="horizontal-title"><span>${escape(a.title)}</span></h3><p class="article-excerpt">${escape(clippedExcerpt(a.excerpt || ""))}</p><div class="record-bottom"><small>${escape(a.published || a.date?.slice(0, 10) || "发布时间未提供")}</small><small>已保存</small></div><div class="record-bottom"><small>${fmt(a.characters)} 字 · ${fmt(a.imageCount)} 张图</small><button class="remove" aria-label="移除记录，保留文件">×</button></div>`;
    const img = tile.querySelector("img");
    if (a.coverPath)
      call("media", { path: a.coverPath })
        .then((u) => (img.src = u))
        .catch(() => img.remove());
    else if (a.coverURL)
      call("cover", { url: a.coverURL })
        .then((u) => (img.src = u))
        .catch(() => img.remove());
    else img.remove();
    tile.querySelector(".article-cover").onclick = async () => {
      $("articleFrame").src = await call("media", { path: a.htmlPath });
      $("reader").showModal();
    };
    tile.querySelector(".reveal").onclick = () =>
      call("reveal", { path: a.path }).catch(() => {});
    tile.querySelector(".remove").onclick = () =>
      call("remove", { kind: "article", id: a.id }).catch(() => {});
    $("articleList").append(tile);
    marquee(tile.querySelector("h3"));
  }
}
async function renderPosts() {
  const stamp = ++renderPosts.seq;
  const filtered = await call("filter-posts", {
    posts,
    filter: {
      start: $("startDateEnabled").checked ? $("startDate").value : "",
      end: $("endDateEnabled").checked ? $("endDate").value : "",
      likes:
        $("likesEnabled").checked && $("likes").value !== ""
          ? Number($("likes").value) * 10000
          : null,
      collects:
        $("collectsEnabled").checked && $("collects").value !== ""
          ? Number($("collects").value) * 10000
          : null,
      keyword: $("keyword").value,
      sort: $("sort").value,
    },
  });
  if (stamp !== renderPosts.seq) return;
  renderPosts.filtered = filtered;
  $("posts").replaceChildren();
  for (const p of filtered.slice(0, 500)) {
    const row = document.createElement("div");
    row.className = "post";
    row.innerHTML = `<input type="checkbox" aria-label="选择作品" ${selected.has(p.id) ? "checked" : ""}><div class="body"><strong>${escape(p.title)}</strong><small>${escape(p.author)} · 点赞 ${fmt(p.diggCount)} · 收藏 ${fmt(p.collectCount)}</small></div>`;
    row.querySelector("input").onchange = (e) =>
      e.target.checked ? selected.add(p.id) : selected.delete(p.id);
    $("posts").append(row);
  }
  if (filtered.length > 500) {
    const more = document.createElement("button");
    more.textContent = `共 ${filtered.length} 项，已显示前500项；全选包含全部符合条件的作品`;
    more.disabled = true;
    $("posts").append(more);
  }
}
renderPosts.seq = 0;
async function browseTo(value) {
  browse = await call("folder-list", { path: value });
  $("browsePath").value = browse.path;
  $("browseList").replaceChildren();
  for (const f of [
    ...(browse.collections || []).map((c) => ({
      ...c,
      name: "学习文件夹 · " + c.name,
    })),
    ...browse.folders,
  ]) {
    const b = document.createElement("button");
    b.textContent = "▱ " + f.name;
    b.onclick = () => browseTo(f.path).catch(() => {});
    $("browseList").append(b);
  }
}
function showChanges(data) {
  $("statsBody").replaceChildren();
  if (!data.changes.length) {
    const p = document.createElement("p");
    p.textContent = "已更新 " + data.processed + " 项，没有可比较的新变化。";
    $("statsBody").append(p);
  }
  for (const item of data.changes) {
    const block = document.createElement("div");
    block.innerHTML = `<h3>${escape(item.title)}</h3>${item.changes.length ? item.changes.map((c) => `<p class="${c.delta > 0 ? "up" : "down"}">${metrics[c.key]}：${fmt(c.before)} → ${fmt(c.after)}　${c.delta > 0 ? "↑ +" : "↓ "}${Math.abs(c.delta).toLocaleString()}</p>`).join("") : "<small>没有可比较的新变化；缺失值不按0计算。</small>"}`;
    $("statsBody").append(block);
  }
  for (const f of data.failures) {
    const p = document.createElement("p");
    p.textContent = f.message;
    $("statsBody").append(p);
  }
  $("statsDialog").showModal();
}
for (const b of document.querySelectorAll("nav button"))
  b.onclick = () => navigate(b.dataset.page).catch(() => {});
document
  .querySelectorAll("[data-quality]")
  .forEach(
    (b) =>
      (b.onclick = () =>
        call("settings", { quality: b.dataset.quality }).catch(() => {})),
  );
document.querySelectorAll(".folder-chooser").forEach(
  (b) =>
    (b.onclick = async () => {
      browseArticle = b.dataset.article === "true";
      await browseTo(
        browseArticle
          ? model.settings.articleFolder || model.settings.folder
          : model.settings.folder,
      );
      $("folderDialog").showModal();
    }),
);
listener("paste", async () => {
  try {
    $("singleLink").value = await call("paste");
  } catch {
    message("请在输入框按 Ctrl+V 粘贴分享。");
  }
});
listener("preview", () =>
  call("task", { kind: "info", link: $("singleLink").value }),
);
listener("download", () =>
  call("task", { kind: "download", link: $("singleLink").value }),
);
listener("cancel", () => call("cancel"));
listener("theme", () =>
  call("settings", {
    theme: model.settings.theme === "light" ? "dark" : "light",
  }),
);
listener("savePhotos", () => call("photo-save"));
listener("cancelPhotos", () => call("photo-cancel"));
listener("photoClose", () => $("photoDialog").close());
listener("photoPrev", async () => {
  photoIndex = (photoIndex + photos.length - 1) % photos.length;
  await updatePhoto();
});
listener("photoNext", async () => {
  photoIndex = (photoIndex + 1) % photos.length;
  await updatePhoto();
});
listener("photoCopy", async () => {
  await call("photo-copy", { path: photos[photoIndex] });
  message("图片已复制");
});
$("photoLarge").oncontextmenu = (e) => {
  e.preventDefault();
  $("photoCopy").click();
};
document.addEventListener("keydown", (e) => {
  if (
    $("photoDialog").open &&
    (e.ctrlKey || e.metaKey) &&
    e.key.toLowerCase() === "c"
  ) {
    e.preventDefault();
    $("photoCopy").click();
  }
});
listener("captureArticle", () => call("article-capture"));
listener("loginDone", () => call("login-close"));
listener("creatorLogin", () =>
  login($("creatorPlatform").value, $("creatorLink").value || undefined),
);
listener("scan", async () => {
  posts = [];
  selected.clear();
  $("scanSummary").hidden = false;
  $("scanSummary").textContent = "正在采集，请稍候…";
  const result = await call("task", {
    kind: "scan",
    platform: $("creatorPlatform").value,
    link: $("creatorLink").value,
  });
  posts = result.posts;
  posts.forEach((p) => selected.add(p.id));
  $("scanSummary").textContent = result.result?.complete
    ? `采集结束：${posts.length} 项`
    : `保留 ${posts.length} 项；当前结果部分可用。${result.result?.detail || result.result?.reason || ""}`;
  renderPosts();
});
for (const id of [
  "startDate",
  "endDate",
  "likes",
  "collects",
  "keyword",
  "sort",
])
  listener(id, renderPosts, "input");
listener("selectPosts", () => {
  if (selected.size) selected.clear();
  else (renderPosts.filtered || posts).forEach((p) => selected.add(p.id));
  renderPosts();
});
listener("enqueuePosts", async () => {
  const collectionID = $("creatorCollection").value;
  if (!collectionID) {
    message("请先选择收藏夹");
    return;
  }
  const n = await call("enqueue-posts", {
    posts: (renderPosts.filtered || posts).filter((p) => selected.has(p.id)),
    homepage: $("creatorLink").value,
    collectionID,
  });
  message("已加入 " + n + " 项");
});
listener("enqueue", async () => {
  if (!$("queueCollection").value) {
    message("请先选择或新建收藏夹");
    return;
  }
  const n = await call("enqueue", {
    text: $("queueText").value,
    collectionID: $("queueCollection").value,
    audio: $("audio").checked,
  });
  message("已加入 " + n + " 项");
});
listener("import", async () => {
  const text = await call("import-text");
  if (text !== null) $("queueText").value = text;
});
listener("startQueue", () => call("queue-start"));
listener("stopQueue", () => call("queue-stop"));
listener("newCollection", async () => {
  const name = await askText("文件夹名称");
  if (name) await call("collection-create", { name, parentID, notes: "" });
});
function back() {
  parentID = model.collections.find((c) => c.id === parentID)?.parentID || null;
  visibleLimit = 60;
  document.querySelector("main").scrollTop = 0;
  renderFolders();
}
listener("folderBack", back);
listener("folderBackBottom", back);
listener(
  "sourceFilter",
  () => renderRecords($("recordList"), filteredRecords()),
  "change",
);
listener(
  "search",
  () => renderRecords($("recordList"), filteredRecords()),
  "input",
);
document.querySelectorAll(".metrics").forEach(
  (b) =>
    (b.onclick = () =>
      call("task", {
        kind: "metrics",
        ids: activeRecords().map((r) => r.id),
      }).catch(() => {})),
);
listener("saveArticles", () =>
  call("task", { kind: "articles", text: $("articleLinks").value }),
);
listener("articleLogin", () =>
  login(
    "wechat",
    $("articleLinks").value.trim().split(/\s/)[0] ||
      "https://mp.weixin.qq.com/",
  ),
);
listener("readerClose", () => {
  $("reader").close();
  $("articleFrame").removeAttribute("src");
});
listener("statsClose", () => $("statsDialog").close());
listener("browseGo", () => browseTo($("browsePath").value));
listener("browseUp", () => browseTo(browse.parent));
listener("browseNew", async () => {
  const name = await askText("新建文件夹名称");
  if (name) {
    await call("folder-create", { parent: browse.path, name });
    await browseTo(browse.path);
  }
});
listener("browseConfirm", async () => {
  await call("settings", { folder: browse.path, article: browseArticle });
  $("folderDialog").close();
});
listener("browseCancel", () => $("folderDialog").close());
api.on((event) => {
  if (event.type === "state") refresh().catch(() => {});
  if (event.type === "message") message(event.message);
  if (event.type === "login-closed") {
    $("loginToolbar").hidden = true;
  }
  if (event.type === "scan-post") {
    posts.push(event.post);
    selected.add(event.post.id);
    if (!renderTimer)
      renderTimer = setTimeout(() => {
        renderTimer = null;
        renderPosts().catch(() => {});
      }, 180);
  }
  if (event.type === "progress") {
    $("progress").hidden = false;
    $("progressDetail").textContent = event.detail || "正在处理";
    $("progressPercent").textContent =
      event.percent === null ? "处理中" : event.percent + "%";
    $("progressFill").style.width = (event.percent ?? 12) + "%";
    $("progressExtra").textContent = event.speed
      ? "速度 " +
        Math.round(event.speed / 1024) +
        " KB/s · 解析 → 下载 → 导出 → 检查"
      : "解析 → 下载 → 导出 → 检查";
  }
  if (event.type === "statistics-changes") showChanges(event);
});
const oldRefresh = refresh;
refresh = async () => {
  await oldRefresh();
  if (!model.busy) {
    $("progress").hidden = true;
    if (
      page === "single" &&
      !model.draft &&
      model.records[0]?.link === $("singleLink").value
    ) {
      $("singleResult").innerHTML =
        '<div class="notice">已保存：' +
        escape(model.records[0].title) +
        "　可在下载记录里播放或定位文件。</div>";
    }
  }
};
refresh().catch(() => {});

listener("creatorClear", () =>
  call("login-clear", { platform: $("creatorPlatform").value }),
);
listener("articlePaste", async () => {
  $("articleLinks").value = await call("paste");
});
listener("footerNew", () => navigate("single"));
listener("moveCancel", () => $("moveDialog").close());
listener("moveConfirm", async () => {
  await call("collection-move", {
    id: moveID,
    parentID: $("moveTarget").value || null,
  });
  $("moveDialog").close();
});
for (const id of [
  "startDateEnabled",
  "endDateEnabled",
  "likesEnabled",
  "collectsEnabled",
])
  listener(id, renderPosts, "change");
for (const id of ["folderSource", "folderSearch"])
  listener(
    id,
    () => {
      visibleLimit = 60;
      renderRecords($("folderRecords"), folderRecords());
    },
    id === "folderSearch" ? "input" : "change",
  );
document.addEventListener("pointerdown", (e) => {
  if (e.button !== 0 || matchMedia("(prefers-reduced-motion: reduce)").matches)
    return;
  const ripple = document.createElement("span");
  ripple.className = "click-ripple";
  ripple.style.left = e.clientX + "px";
  ripple.style.top = e.clientY + "px";
  document.body.append(ripple);
  ripple.addEventListener("animationend", () => ripple.remove(), {
    once: true,
  });
});

listener("resumeScan", async () => {
  const previous = model.scanState;
  if (!previous) return;
  posts = previous.posts.slice();
  $("creatorLink").value = previous.link;
  $("creatorPlatform").value = previous.platform;
  posts.forEach((p) => selected.add(p.id));
  const result = await call("task", {
    kind: "scan",
    platform: previous.platform,
    link: previous.link,
    resume: true,
  });
  posts = result.posts;
  renderPosts();
  $("scanSummary").textContent = result.result?.complete
    ? "采集结束：" + posts.length + " 项"
    : "保留 " + posts.length + " 项；可用范围或分页边界见状态。";
});
