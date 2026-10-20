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
  postLimit = 500,
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
// Keep the same primary controls visible in the fixed bottom bar on either page.
const oldPhotoActions = $("savePhotos").parentElement, oldDownloadActions = $("download").parentElement;
for (const id of ["cancelPhotos", "savePhotos", "download", "cancelCreatorCovers", "saveCreatorCovers"]) $("footerCapture").append($(id));
oldPhotoActions.remove(); oldDownloadActions.remove();
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

function renderRelease(value) {
  if (!value) return;
  $("checkRelease").disabled = value.checking;
  $("checkRelease").textContent = value.checking ? "正在检查更新…" : "检查更新";
  $("releaseStatus").textContent = value.message;
  $("releaseBanner").hidden = !value.available;
  $("releaseTitle").textContent = value.available ? `拾影 ${value.available.version} 已发布` : "";
}
listener("githubStar", () => call("release-project"));
listener("checkRelease", async () => renderRelease(await call("release-check")));
listener("releaseDownload", () => call("release-download"));
listener("releaseNotes", () => call("release-notes"));
function stopPlayer() {
  document.querySelectorAll("video").forEach((v) => {
    v.pause();
    v.removeAttribute("src");
    v.load();
    v.closest(".playback-area")?.remove();
    v.remove();
  });
  playing = null;
  document
    .querySelectorAll(".record-cover [data-video-glyph]")
    .forEach((g) => (g.textContent = "▶"));
}
function mountPlayback(card,video,id) {
  const area=document.createElement('div');area.className='playback-area';
  area.innerHTML='<div class="playback-controls"><button class="play-pause" aria-label="暂停或继续播放">暂停</button><span class="play-time">0:00 / 0:00</span><input class="play-progress" type="range" min="0" max="1" step="0.001" value="0" aria-label="播放进度"><select class="play-rate" aria-label="播放倍速">'+[.5,.75,1,1.25,1.5,2,3].map(n=>`<option value="${n}" ${n===1?'selected':''}>${n}×</option>`).join('')+'</select></div>';
  area.prepend(video);card.append(area);
  const range=area.querySelector('.play-progress'),pause=area.querySelector('.play-pause');
  const time=n=>`${Math.floor((n||0)/60)}:${String(Math.floor((n||0)%60)).padStart(2,'0')}`;
  const update=()=>{if(playing!==id)return;range.value=video.duration>0?video.currentTime/video.duration:0;area.querySelector('.play-time').textContent=time(video.currentTime)+' / '+time(video.duration);pause.textContent=video.paused?'继续':'暂停';};
  for(const event of ['timeupdate','loadedmetadata','play','pause','ended'])video.addEventListener(event,update);
  pause.onclick=()=>video.paused?video.play().catch(()=>{}):video.pause();
  range.oninput=()=>{if(Number.isFinite(video.duration)&&video.duration>0)video.currentTime=Number(range.value)*video.duration;};
  area.querySelector('.play-rate').onchange=e=>video.playbackRate=Number(e.target.value);
}
function updateQueueFooter() {
  if(!model)return;
  const q=model.queue,done=q.filter(x=>x.status==='completed').length,failed=q.filter(x=>x.status==='failed').length;
  if(model.queueRunning||model.queuePaused) {
    $('footerTitle').textContent=model.progress?.detail || (model.queuePaused?'批量队列已暂停':'批量队列运行中');
    $('footerStats').textContent=`全部任务：待 ${q.filter(x=>x.status==='pending').length} · 完成 ${done} · 失败 ${failed} · 共 ${q.length}`;
  } else {$('footerTitle').textContent=model.busy?'正在处理':'准备就绪';$('footerStats').textContent='文件保存在你的电脑';}
  if(model.queueRunning||model.queuePaused){
    let group=$('footerQueue');if(!group){group=document.createElement('div');group.id='footerQueue';group.className='row';$('footerCapture').after(group);}group.replaceChildren();group.hidden=false;$('footerCapture').hidden=true;$('footerNew').hidden=true;
    for(const [label,action] of (model.queueRunning?[['暂停','queue-pause'],['取消当前','queue-stop']]:[['继续','queue-resume']])) {
      const b=document.createElement('button');b.textContent=label;b.onclick=()=>call(action).catch(()=>{});group.append(b);
    }
  } else {$('footerNew').hidden=false;if($('footerQueue'))$('footerQueue').hidden=true;}
  $('pauseQueue').disabled=!model.queueRunning;$('resumeQueue').disabled=!model.queuePaused||model.busy;$('stopQueue').disabled=!model.queueRunning;
}
function updatePostSummary() {
  const filtered=renderPosts.filtered||[];
  let node=$('postSummary');if(!node){node=document.createElement('div');node.id='postSummary';$('posts').before(node);}
  node.textContent=`符合 ${filtered.length} · 已选 ${filtered.filter(p=>selected.has(p.id)).length} · 未知字段 ${filtered.filter(p=>p.diggCount==null||p.collectCount==null).length}`;
  if(page==='creator')$('headerMatches').textContent=filtered.length;
  const badge=document.querySelector('[data-page="creator"] .nav-badge');if(badge){badge.textContent=filtered.length;badge.hidden=!filtered.length;}
}
function renderMultiple() {
  const items=model.multiItems||[],container=$('multiLinks');container.hidden=!items.length;$('multiDownloadAll').hidden=!items.length;
  $('multiDownloadAll').disabled=model.busy||!items.some(x=>x.status==='ready');
  if(!items.length){container.replaceChildren();return;}
  container.replaceChildren();
  const labels={pending:'等待解析',parsing:'正在解析',ready:'可下载',awaiting:'等待确认保存',downloading:'正在下载',completed:'已保存',failed:'失败',cancelled:'已取消'};
  for(const [index,item] of items.entries()) {
    const card=document.createElement('article');card.className='glass multi-link-card';card.dataset.linkId=item.id;
    card.innerHTML=`<div class="row between"><strong>${index+1}. ${escape(item.metadata?.title||'作品')}</strong><small>${labels[item.status]}</small></div><div class="multi-source">${escape(item.metadata?.author||'')} · ${escape(item.link)}</div><div class="multi-images"></div><progress max="100" value="${item.progress||0}"></progress><p class="error">${escape(item.error||'')}</p><div class="row multi-actions"></div>`;
    card.querySelector('progress').hidden=!['parsing','downloading','completed'].includes(item.status);
    card.querySelector('.error').hidden=!item.error;
    const actions=card.querySelector('.multi-actions');
    function button(label,action){const b=document.createElement('button');b.textContent=label;b.disabled=model.busy;b.onclick=()=>call('multi-action',{id:item.id,action}).catch(()=>{});actions.append(b);}
    if(item.status==='ready')button('下载这条','download');
    if(item.hasDraft){button('确认保存','confirm');button('取消保存','cancel');}
    if(['failed','cancelled'].includes(item.status))button(item.downloadFailed?'重试下载':'重新解析／重试','retry');
    container.append(card);
    for(const file of item.images||[]) {
      const image=document.createElement('img');image.alt='临时图片';card.querySelector('.multi-images').append(image);
      api.call('media',{path:file}).then(url=>{if(image.isConnected)image.src=url;}).catch(()=>{});
      image.onclick=()=>showPhotos(item.images,item.images.indexOf(file));image.oncontextmenu=e=>{e.preventDefault();call('photo-copy',{path:file}).catch(()=>{});};
    }
  }
}
function renderSubscriptions() {
  const platform=$('creatorPlatform').value,container=$('subscriptionsList');container.replaceChildren();
  const unsupported=platform==='wechat';$('subscribeCurrent').disabled=model.busy||unsupported||!model.scanState?.creator||model.scanState.platform!==platform;
  $('subscriptionHint').textContent=model.subscriptionsError||(unsupported?'视频号暂不支持博主主页订阅':platform==='xiaohongshu'?'小红书只更新当前可访问主页结果':'');
  for(const row of (model.subscriptions||[]).filter(x=>x.platform===platform)) {
    const card=document.createElement('div');card.className='glass subscription-card';
    card.innerHTML=`<strong>${escape(row.name)}</strong><small>${escape(names[row.platform])} · ${escape(model.collections.find(c=>c.id===row.collectionID)?.name||'目录已不存在')} · ${escape(row.quality)} · 新增 ${row.lastAddedCount||0}</small><p>${escape(row.lastMessage||'尚未更新')}</p><div class="row"><button class="update-subscription">手动更新</button><button class="remove-subscription">取消订阅</button></div>`;
    card.querySelector('.update-subscription').disabled=model.busy;card.querySelector('.remove-subscription').disabled=model.busy;
    card.querySelector('.update-subscription').onclick=()=>call('subscription-update',{id:row.id}).then(r=>message(`本次新增 ${r.added} 条`)).catch(()=>{});
    card.querySelector('.remove-subscription').onclick=()=>call('unsubscribe',{id:row.id}).catch(()=>{});container.append(card);
  }
}
async function navigate(next) {
  if (model?.busy && next !== page) {
    message("任务处理中，请等待完成或取消");
    return;
  }
  if ((model?.draft && model.draft.owner === page || model?.multiItems?.length && page === "single") && next !== page) await invalidateDraft();
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
  renderRelease(model.releaseUpdate);
  document.body.classList.toggle("light", model.settings.theme === "light");
  $("version").textContent = "拾影 " + model.version + " · Windows x64";
  $("savedCount").textContent = "本地收藏 " + model.records.length + " 个作品";
  const counts={creator:(renderPosts.filtered||[]).length,articles:model.articles.length,queue:model.queue.filter(q=>q.status==='pending').length,folders:model.collections.length,records:model.records.filter(r=>r.fromBatch===false||(r.fromBatch==null&&(!r.collectionID||r.mediaKind==='video_cover'))).length};
  for(const button of document.querySelectorAll('nav button')){let badge=button.querySelector('.nav-badge');if(!badge){badge=document.createElement('b');badge.className='nav-badge';button.append(badge);}badge.hidden=!counts[button.dataset.page];badge.textContent=counts[button.dataset.page]||'';}
  $('revealComplete').checked=!!model.settings.revealOnComplete;$('revealComplete').disabled=model.busy;
  for(const [id,theme] of [['themeLight','light'],['themeDark','dark']])$(id).classList.toggle('selected',model.settings.theme===theme);
  $('headerMatches').textContent=page==='creator'?(renderPosts.filtered||[]).length:page==='single'?(model.multiItems?.length||0):0;
  $("blocked").hidden = !model.blocked;
  $("blocked").textContent = model.blocked || "";
  $("headerSaved").textContent =
    page === "articles"
      ? model.articles.filter((a) => (a.status || "saved") === "saved").length
      : model.records.length;
  $("headerPending").textContent = model.queue.filter((q) =>
    ["pending", "running"].includes(q.status),
  ).length;
  $("headerBusy").textContent = model.queueRunning ? '▣ 队列运行中' : model.busy ? "◇ 处理中" : "◇ 空闲";
  $("creatorClear").disabled = model.busy;
  document.querySelectorAll("[data-platform]").forEach((b) => {
    b.disabled = model.busy;
    b.classList.toggle(
      "selected",
      b.dataset.platform === $("creatorPlatform").value,
    );
  });
  $("footerNew").disabled = model.busy;
  document
    .querySelectorAll("[data-quality]")
    .forEach((b) => (b.disabled = model.busy));
  $("status").textContent = {creator:'抖音 · B站 · 视频号 · 小红书',single:'把视频与图文，收进自己的收藏',queue:'多链接导入，或从博主主页筛选后下载',articles:'文章链接，保存正文与图片',folders:'归类素材，记录学习备注',records:'每次保存，都能在这里找到',about:'三步保存作品'}[page];
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
    "downloadPosts",
    "saveCreatorCovers",
    "cancelCreatorCovers",
    "cancelPhotos",
    "singleLink",
    "creatorLink",
    "creatorAudio",
    "singleVideo", "singleCover", "creatorVideo", "creatorCover",
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
    if (model.collections.some((c) => c.id === previous)) select.value = previous;
    else select.value=model.collections.find(c=>c.path===model.settings.folder)?.id || model.collections[0]?.id || "";
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
  updateCaptureControls();
  renderMultiple();renderSubscriptions();
  renderMetadata();
  await renderDraft();
  syncPhotoActions();
  updateQueueFooter();
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
  $("metadata").hidden = !m || !!model.multiItems?.length;
  if (m) {
    const duration =
      model.draft?.kind === "video_cover" ? "封面原图" : m.duration > 0
        ? `${Math.floor(m.duration / 60)}:${String(Math.floor(m.duration) % 60).padStart(2, "0")}`
        : "时长待核验";
    $("metadata").innerHTML =
      `<strong>${escape(m.title)}</strong><span>${escape(m.author)}</span><span>${duration}</span><span>${m.size ? (m.size / 1024 / 1024).toFixed(1) + " MB" : ""}</span>`;
  }
}
function captureOptions(owner) { return { video: $(owner + "Video").checked, cover: $(owner + "Cover").checked }; }
function updateCaptureControls() {
  for (const owner of ["single", "creator"]) {
    const o = captureOptions(owner), valid = o.video || o.cover;
    $(owner + "CaptureHint").textContent = !valid ? "请至少选择一项采集内容。" : o.cover ? "封面先临时下载，可右键复制；确认后保存，取消后清理。" : "";
    for (const id of owner === "single" ? ["preview", "download"] : ["scan", "enqueuePosts", "downloadPosts"]) $(id).disabled = !valid || model?.busy || !!model?.blocked;
  }
  $("singleQuality").hidden = !$("singleVideo").checked || model?.draft?.kind === "image_album";
  $("creatorAudio").disabled = model?.busy || !$("creatorVideo").checked;
  $("enqueuePosts").textContent = $("creatorCover").checked ? "临时采集选中封面" : "将选中作品加入队列";
  $("enqueuePosts").hidden = !$("creatorVideo").checked || model?.draft?.owner === "creator";
  $("enqueuePosts").textContent = $("creatorCover").checked ? "预览封面 · 稍后入队" : "只加入队列";
  $("downloadPosts").hidden = model?.draft?.owner === "creator";
  $("downloadPosts").textContent = $("creatorCover").checked ? $("creatorVideo").checked ? "预览封面 · 稍后下载视频" : "临时下载封面" : "下载筛选结果";
  const pending = model?.draft?.owner === page;
  $("footerCapture").hidden = page !== "single" && !pending;
  $("footerNew").hidden = page === "single" || pending;
  $("download").hidden = page !== "single" || !!model?.draft;
  $("download").textContent = $("singleCover").checked && !$("singleVideo").checked ? "临时下载封面" : "开始下载";
  $("singlePreviewHint").textContent = $("singleCover").checked ? "封面解析后自动临时下载，可右键复制，确认后保存" : "图文解析后自动临时下载，可右键复制，确认后保存";
  for (const id of ["savePhotos", "cancelPhotos"]) $(id).hidden = !pending || page !== "single";
  for (const id of ["saveCreatorCovers", "cancelCreatorCovers"]) $(id).hidden = !pending || page !== "creator";
}
async function invalidateDraft(owner = null) {
  if(model?.multiItems?.length && (!owner||owner==='single')) {
    if(model.busy)return;
    if($('photoDialog').open)$('photoDialog').close();photos=[];
    await call('photo-cancel');return;
  }
  if (!model?.draft || (owner && owner !== model.draft.owner)) return;
  if (model.busy) return;
  if (photos.some((p) => model.draft.imagePaths.includes(p))) { $("photoDialog").close(); photos = []; }
  await call("photo-cancel");
}
async function renderDraft() {
  const seq = ++renderDraft.seq, d = model.draft;
  $("photoDraft").hidden = !d || d.owner !== "single";
  $("creatorDraft").hidden = !d || d.owner !== "creator";
  if (!d) { $("draftImages").replaceChildren(); $("creatorDraftImages").replaceChildren(); return; }
  const creator = d.owner === "creator", grid = $(creator ? "creatorDraftImages" : "draftImages");
  grid.replaceChildren();
  $(creator ? "creatorDraftTitle" : "singleDraftTitle").textContent = (d.kind === "video_cover" ? "临时封面" : "临时图文") + " · " + d.imagePaths.length + " 张 · 确认后才写入收藏";
  const failures = $(creator ? "creatorDraftFailures" : "singleDraftFailures");
  failures.hidden = !d.failures?.length; failures.textContent = d.failures?.join("；") || "";
  const confirm = $(creator ? "saveCreatorCovers" : "savePhotos");
  confirm.disabled = model.busy || !!model.blocked || !!d.failures?.length || !d.imagePaths.length;
  confirm.textContent = d.kind === "video_cover" && d.selection?.video ? creator ? d.startImmediately ? "确认保存并下载视频" : "确认保存并加入队列" : "确认保存并下载视频" : "确认保存";
  for (const file of d.imagePaths) {
    const image = document.createElement("img"); image.alt = d.kind === "video_cover" ? "临时封面" : "临时图文";
    let url; try { url = await api.call("media", { path: file }); } catch (e) { if (seq !== renderDraft.seq || !model.draft?.imagePaths.includes(file)) return; throw e; }
    if (seq !== renderDraft.seq) return;
    image.src = url;
    image.onclick = () => showPhotos(d.imagePaths, d.imagePaths.indexOf(file));
    image.oncontextmenu = (e) => { e.preventDefault(); call("photo-copy", { path: file }).then(() => message("图片已复制，可直接粘贴")).catch(() => {}); };
    grid.append(image);
  }
}
renderDraft.seq = 0;
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
  syncPhotoActions();
  $("photoDialog").showModal();
}
function syncPhotoActions() {
  const multi=(model.multiItems||[]).find(item=>item.hasDraft&&photos.length&&photos.every(p=>item.images.includes(p)));
  const current=multi?{owner:'single',imagePaths:multi.images}:model.draft;
  const pending = current && photos.length && photos.every((p) => current.imagePaths.includes(p));
  $('photoDialog').dataset.multiID=multi?.id||'';
  $("photoConfirm").hidden = $("photoCancel").hidden = !pending;
  $("photoConfirm").disabled = model.busy || !!model.blocked || !!model.draft?.failures?.length;
  $("photoConfirm").textContent = pending ? $(current.owner === "creator" ? "saveCreatorCovers" : "savePhotos").textContent : "确认保存";
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
      (r.fromBatch===false || r.fromBatch==null&&(!r.collectionID||r.mediaKind==='video_cover')) &&
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
      (r.collectionID === parentID || r.destinationCollectionID === parentID) &&
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
  const fingerprint=JSON.stringify([visibleLimit,records.map(r=>[r.id,r.available,r.audioError]),model.statistics]);
  if(container.dataset.fingerprint===fingerprint)return;container.dataset.fingerprint=fingerprint;
  const seq = ++renderSequence;
  const preserved=playing&&records.slice(0,visibleLimit).some(r=>r.id===playing)?container.querySelector(`[data-record="${playing}"] .playback-area`):null;
  if(preserved)preserved.remove();else stopPlayer();
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
    card.innerHTML = `<div class="tile-top"><button class="record-cover" aria-label="展开／收回播放"><img alt="作品封面"><span class="play" ${!["image_album", "video_cover"].includes(r.mediaKind) ? "data-video-glyph" : ""}>${["image_album", "video_cover"].includes(r.mediaKind) ? "▧" : "▶"}</span></button><div class="tile-info"><div class="tile-author-row"><span class="author">${escape(r.author || "未知作者")}</span><button class="reveal" aria-label="在文件夹中显示">▱</button></div><span class="source-tag">${escape(names[r.platform] || "来源待确认")}${r.mediaKind === "video_cover" ? " · 封面" : ""}</span></div></div><h3 class="horizontal-title"><span>${escape(r.title)}</span></h3><div class="description">${escape(r.description)}</div><div class="tags"></div><div class="stats">${Object.entries(
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
    const play = card.querySelector(".record-cover"),
      glyph = play.querySelector(".play");
    play.disabled = r.available === false;
    play.onclick = async () => {
      if (["image_album", "video_cover"].includes(r.mediaKind)) {
        await showPhotos(r.imagePaths);
        return;
      }
      if (playing === r.id) {
        stopPlayer();
        glyph.textContent = "▶";
        return;
      }
      stopPlayer();
      playing = r.id;
      glyph.textContent = "■";
      const video = document.createElement("video");
      video.controls = false;
      video.className = "inline-player";
      video.preload = "metadata";
      video.src = await call("media", { path: r.path });
      if (playing !== r.id) return;
      mountPlayback(card,video,r.id);
      video.onerror = () =>
        message("原视频不可用或暂无法解码，已保存文件保留。");
      await video.play().catch(() => {});
    };
    const img = card.querySelector("img");
    let source;
    if (["image_album", "video_cover"].includes(r.mediaKind) && r.imagePaths?.[0])
      source = call("media", { path: r.imagePaths[0] });
    else
      source = api
        .call("cover", { url: stats.coverURL || r.cover })
        .catch(() => api.call("thumbnail", { path: r.path }));
    source
      .then((url) => {
        if (seq === renderSequence) img.src = url;
      })
      .catch(() => {
        img.remove();
        play.disabled = r.available === false;
      });
    container.append(card);
    if(preserved && playing===r.id){card.append(preserved);glyph.textContent='■';}
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
  const container = $("articleList");
  container.replaceChildren();
  for (const a of model.articles.slice(0, visibleLimit)) {
    const tile = document.createElement("article");
    tile.className = "glass article-tile";
    const status =
      a.attemptStatus === "processing"
        ? "正在保存"
        : (a.status || "saved") === "saved"
          ? "已保存"
          : a.status === "failed"
            ? "保存失败"
            : "正在保存";
    tile.innerHTML = `<div class="tile-top"><button class="record-cover article-cover" aria-label="打开文章正文"><img alt="公众号封面"><span class="play">▶</span></button><div class="author">${escape(a.account || a.author || "公众号")}<small>${escape(a.author && a.author !== a.account ? a.author : "")}</small></div></div><div class="record-top"><span class="source-tag">公众号</span><button class="reveal" aria-label="显示文章文件夹">▱</button></div><h3 class="horizontal-title"><span>${escape(a.title)}</span></h3><p class="article-excerpt">${escape(clippedExcerpt(a.excerpt || a.error || "正文尚未保存"))}</p><div class="record-bottom"><small>${escape(a.published || a.date?.slice(0, 10) || "发布时间未提供")}</small><small>${status}</small></div><div class="record-bottom"><button class="resave">${a.htmlPath ? "重新保存" : "保存"}</button><button class="original">原文</button><button class="remove" aria-label="移除记录，保留文件">×</button></div>`;
    const img = tile.querySelector("img");
    if (a.coverPath)
      api
        .call("media", { path: a.coverPath })
        .then((u) => (img.src = u))
        .catch(() => img.remove());
    else if (a.coverURL)
      api
        .call("cover", { url: a.coverURL })
        .then((u) => (img.src = u))
        .catch(() => img.remove());
    else img.remove();
    tile.querySelector(".article-cover").onclick = async () => {
      if (a.htmlPath && a.available !== false) {
        $("articleFrame").src = await call("media", { path: a.htmlPath });
        $("reader").showModal();
      } else await login("wechat", a.link);
    };
    tile.querySelector(".reveal").disabled = !a.path;
    tile.querySelector(".reveal").onclick = () =>
      call("reveal", { path: a.path }).catch(() => {});
    tile.querySelector(".resave").disabled = model.busy;
    tile.querySelector(".resave").onclick = () =>
      call("task", { kind: "articles", text: a.link }).catch(() => {});
    tile.querySelector(".original").disabled = model.busy;
    tile.querySelector(".original").onclick = () =>
      login("wechat", a.link).catch(() => {});
    tile.querySelector(".remove").disabled = model.busy;
    tile.querySelector(".remove").onclick = () =>
      call("remove", { kind: "article", id: a.id }).catch(() => {});
    container.append(tile);
    marquee(tile.querySelector("h3"));
  }
  if (model.articles.length > visibleLimit) {
    const more = document.createElement("button");
    more.className = "show-more";
    more.textContent = "显示更多文章";
    more.onclick = () => {
      visibleLimit += 60;
      renderArticles();
    };
    container.append(more);
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
  for (const p of filtered.slice(0, postLimit)) {
    const row = document.createElement("div");
    row.className = "post";
    row.innerHTML = `<img class="post-cover" alt="作品封面"><input type="checkbox" aria-label="选择作品" ${selected.has(p.id) ? "checked" : ""}><div class="body"><strong>${escape(p.title)}</strong><small>${escape(p.author)} · 点赞 ${fmt(p.diggCount)} · 收藏 ${fmt(p.collectCount)}</small></div>`;
    if(Number.isFinite(p.createTime))row.querySelector('small').prepend(new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(p.createTime*1000))+' · ');
    const cover=p.cover || p.coverURL || p.statistics?.coverURL;
    if(cover)api.call("cover",{url:cover}).then(url=>{if(row.isConnected)row.querySelector("img").src=url;}).catch(()=>row.querySelector("img")?.remove());else row.querySelector("img").remove();
    row.querySelector("input").disabled = !!model.busy;
    row.querySelector("input").onchange = async (e) => { await invalidateDraft("creator"); e.target.checked ? selected.add(p.id) : selected.delete(p.id); updatePostSummary(); };
    $("posts").append(row);
  }
  updatePostSummary();
  if (filtered.length > postLimit) {
    const more = document.createElement("button");
    more.textContent = `共 ${filtered.length} 项，点击显示更多；全选包含全部符合条件的作品`;
    more.onclick = () => {
      postLimit += 500;
      renderPosts().catch(() => {});
    };
    $("posts").append(more);
  }
}
renderPosts.seq = 0;
async function browseTo(value, fallback = false) {
  browse = await call("folder-list", { path: value, fallback });
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
        true,
      );
      $("folderDialog").showModal();
    }),
);
listener("paste", async () => {
  try {
    await invalidateDraft("single");
    $("singleLink").value = await call("paste");
  } catch {
    message("请在输入框按 Ctrl+V 粘贴分享。");
  }
});
listener("preview", () =>
  call("task", { kind: "info", link: $("singleLink").value, selection: captureOptions("single") }),
);
listener("download", () => model.multiItems?.length ? call("multi-action",{action:"all"}) : call("task",{kind:"download",link:$("singleLink").value,selection:captureOptions("single")}));
listener("cancel", () => call("cancel"));
listener("theme", () =>
  call("settings", {
    theme: model.settings.theme === "light" ? "dark" : "light",
  }),
);
listener("savePhotos", () => call("photo-save"));
listener("cancelPhotos", () => invalidateDraft());
listener("saveCreatorCovers", () => call("photo-save"));
listener("cancelCreatorCovers", () => invalidateDraft());
for (const owner of ["single", "creator"]) {
  listener(owner + "Link", () => invalidateDraft(owner), "input");
  for (const type of ["Video", "Cover"]) listener(owner + type, async () => { await invalidateDraft(owner); updateCaptureControls(); }, "change");
}
listener("photoClose", () => $("photoDialog").close());
listener("photoConfirm", async () => { const id=$('photoDialog').dataset.multiID;$("photoDialog").close(); await call(id?'multi-action':'photo-save',id?{id,action:'confirm'}:undefined); });
listener("photoCancel", async () => { const id=$('photoDialog').dataset.multiID;$("photoDialog").close(); if(id)await call('multi-action',{id,action:'cancel'});else await invalidateDraft(); });
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
  postLimit = 500;
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
    : `保留 ${posts.length} 项；当前结果部分可用。${result.result?.message || result.result?.detail || result.result?.reason || ""}`;
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
  listener(id, async () => { await invalidateDraft("creator"); await renderPosts(); }, "input");
listener("selectPosts", async () => {
  if (model.busy) return;
  await invalidateDraft("creator");
  if (selected.size) selected.clear();
  else (renderPosts.filtered || posts).forEach((p) => selected.add(p.id));
  renderPosts();
});
async function submitCreator(startImmediately) {
  const collectionID = $("creatorCollection").value;
  if (!collectionID) { message("请先选择收藏夹"); return; }
  const value = { posts: (renderPosts.filtered || posts).filter((p) => selected.has(p.id)), homepage: $("creatorLink").value, collectionID, selection: captureOptions("creator"), audio: $("creatorAudio").checked, startImmediately };
  if (!value.posts.length) { message("请先选中作品"); return; }
  if (value.selection.cover) await call("task", { ...value, kind: "creator-covers" });
  else { const n = await call("enqueue-posts", value); message("已加入 " + n + " 项"); }
}
listener("enqueuePosts", () => submitCreator(false));
listener("downloadPosts", () => submitCreator(true));
listener("creatorCollection", () => invalidateDraft("creator"), "change");
listener("creatorAudio", () => invalidateDraft("creator"), "change");
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
listener("pauseQueue",()=>call("queue-pause"));
listener("resumeQueue",()=>call("queue-resume"));
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
  if (event.type === "release-update") { renderRelease(event.releaseUpdate); return; }
  if(event.type==='scan-start') {if(!event.resume){posts=[];selected.clear();}$('creatorPlatform').value=event.platform;$('creatorLink').value=event.link;}
  if (event.type === "state") refresh().catch(() => {});
  if (event.type === "message") message(event.message);
  if (event.type === "login-closed") {
    $("loginToolbar").hidden = true;
  }
  if (event.type === "scan-post") {
    if(!posts.some(p=>p.id===event.post.id))posts.push(event.post);
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
      event.percent === null ? "处理中" : Math.round(event.percent*10)/10 + "%";
    $("progressFill").style.width = (event.percent ?? 12) + "%";
    updateQueueFooter();
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
      $("singleResult").classList.add("record-grid");
      renderRecords($("singleResult"), [model.records[0]]);
    }
  }
};
refresh().catch(() => {});

listener("creatorClear", () =>
  call("login-clear", { platform: $("creatorPlatform").value }),
);
listener('multiDownloadAll',()=>call('multi-action',{action:'all'}));
listener('creatorSubscriptions',()=>{$('subscriptionsDialog').showModal();renderSubscriptions();});
listener('subscriptionsClose',()=>$('subscriptionsDialog').close());
listener('subscribeCurrent',()=>call('subscribe',{platform:$('creatorPlatform').value,collectionID:$('creatorCollection').value,audio:$('creatorAudio').checked}));
listener('revealComplete',()=>call('settings',{revealOnComplete:$('revealComplete').checked}),'change');
listener('themeLight',()=>call('settings',{theme:'light'}));listener('themeDark',()=>call('settings',{theme:'dark'}));
listener('creatorCollection',()=>{const c=model.collections.find(x=>x.id===$('creatorCollection').value);if(c)call('settings',{folder:c.path}).catch(()=>{});},'change');
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
  listener(id, async () => { await invalidateDraft("creator"); await renderPosts(); }, "change");
listener("creatorPlatform", () => invalidateDraft("creator"), "change");
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

document.querySelectorAll("[data-platform]").forEach(
  (b) =>
    (b.onclick = () => {
      if (model.busy) return;
      $("creatorPlatform").value = b.dataset.platform;
      $("creatorPlatform").dispatchEvent(new Event("change"));
      document
        .querySelectorAll("[data-platform]")
        .forEach((x) => x.classList.toggle("selected", x === b));
    }),
);
