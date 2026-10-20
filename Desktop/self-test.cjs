"use strict";
const fs = require("node:fs"),
  path = require("node:path"),
  assert = require("node:assert/strict"),
  { spawnSync } = require("node:child_process");
const { Runner } = require("./runner.cjs"),
  core = require("./core.cjs");
async function selfTest(ctx) {
  const { app, win, library, profile, tools, worker, dataRoot, mediaURL } = ctx;
  const checks = [];
  const record = (name, value) => {
    assert(value, name);
    checks.push({ name, passed: true });
    console.log("SHIYING_CHECK_PASS " + name);
  };
  const arg = process.argv.find((x) => x.startsWith("--self-test-report=")),
    report = arg
      ? arg.slice("--self-test-report=".length)
      : path.join(dataRoot, "self-test.json");
  try {
    await win.webContents.executeJavaScript(
      "new Promise(r=>setTimeout(r,200))",
    );
    record(
      "renderer loaded",
      await win.webContents.executeJavaScript(
        "document.querySelector('#download').textContent.includes('开始下载')",
      ),
    );
    record(
      "renderer has no Node integration",
      await win.webContents.executeJavaScript(
        "typeof window.require==='undefined' && typeof process==='undefined'",
      ),
    );
    record(
      "renderer IPC reaches isolated application data",
      await win.webContents.executeJavaScript(
        "window.shiying.call('state').then(s=>s.records.length===0&&!s.busy)",
      ),
    );
    record(
      "renderer completed startup without a script error",
      !ctx.rendererErrors.length && await win.webContents.executeJavaScript(
        "document.querySelector('#version').textContent.includes('1.8.7')",
      ),
    );
    // Use the real renderer, preload and main-process handlers with public synthetic metadata.
    const releaseModule = require('./release-updates.cjs');
    const openedReleaseURLs = [], releaseName = 'Shiying-1.8.8-Windows-x64-Setup.exe';
    ctx.setReleaseOpener(url => { openedReleaseURLs.push(url); });
    ctx.releaseUpdates.fetcher = async () => new Response(JSON.stringify({ tag_name:'v1.8.8', draft:false, prerelease:false,
      html_url:releaseModule.projectURL+'/releases/tag/v1.8.8', assets:[{name:releaseName,state:'uploaded',size:123,
        browser_download_url:releaseModule.projectURL+'/releases/download/v1.8.8/'+releaseName}] }));
    await win.webContents.executeJavaScript("document.querySelector('#githubStar').click();window.shiying.call('release-check')");
    await win.webContents.executeJavaScript("new Promise(r=>setTimeout(r,80))");
    record('GitHub Star icon opens the Windows project', openedReleaseURLs[0] === releaseModule.projectURL);
    record('new release appears in the real renderer without changing the active page', await win.webContents.executeJavaScript(
      "!document.querySelector('#releaseBanner').hidden && document.querySelector('#releaseTitle').textContent.includes('1.8.8') && page==='single'"));
    await win.webContents.executeJavaScript("window.shiying.call('release-download',{url:'https://evil.test'});window.shiying.call('release-notes')");
    await win.webContents.executeJavaScript("new Promise(r=>setTimeout(r,80))");
    record('download and notes handlers use verified Windows release URLs, ignoring renderer-supplied URLs',
      openedReleaseURLs[1] === releaseModule.projectURL+'/releases/download/v1.8.8/'+releaseName && openedReleaseURLs[2] === releaseModule.projectURL+'/releases/tag/v1.8.8');
    const releaseBefore = JSON.stringify(library.state);
    await ctx.releaseUpdates.check(true);
    record('release checks preserve the library and leave media operations idle', releaseBefore === JSON.stringify(library.state) && !(await ctx.state()).busy);
    await win.webContents.executeJavaScript("navigate('creator')");
    await win.webContents.executeJavaScript(
      "document.querySelector('[data-calendar=startDate]').click();document.querySelector('#calendarHeading').click();document.querySelector('#calendarHeading').click();document.querySelector('#calendarGrid button:not(:disabled)').click();document.querySelector('#calendarGrid button').click();document.querySelector('#calendarGrid button:not(.outside):not(:disabled)').click();",
    );
    record(
      "year/month/day calendar commits and enables a real date filter",
      await win.webContents.executeJavaScript(
        "/^\\d{4}-\\d{2}-\\d{2}$/.test(document.querySelector('#startDate').value)&&document.querySelector('#startDateEnabled').checked",
      ),
    );
    await win.webContents.executeJavaScript(
      "document.querySelector('[data-calendar=startDate]').click();document.querySelector('#calendarNext').click();document.querySelector('#calendarClose').click();",
    );
    record(
      "login actions remain on the homepage title row",
      await win.webContents.executeJavaScript(
        "document.querySelector('#creatorLogin').closest('.section-title')===document.querySelector('#creatorClear').closest('.section-title')",
      ),
    );
    await win.webContents.executeJavaScript("navigate('single')");
    const dir = path.join(dataRoot, "中文 文件夹 #1");
    fs.mkdirSync(dir);
    library.update((d) => (d.settings.folder = dir));
    const c = library.create("学习素材", null, "保留备注");
    record(
      "collection durable",
      new core.Library(dataRoot).collection(c.id).notes === "保留备注",
    );
    const sess = profile("wechat");
    await sess.cookies.set({
      url: "https://yuanbao.tencent.com/",
      name: "hy_user",
      value: "isolated-self-test-user",
      expirationDate: Date.now() / 1000 + 3600,
    });
    await sess.cookies.set({
      url: "https://yuanbao.tencent.com/",
      name: "hy_token",
      value: "isolated-self-test-token",
      expirationDate: Date.now() / 1000 + 3600,
    });
    await sess.cookies.flushStore();
    record(
      "own platform session exported",
      core.hasSession(
        "wechat",
        core.cookieEnvelope("wechat", await sess.cookies.get({})),
      ),
    );
    record(
      "platform session remains isolated",
      !core.hasSession(
        "douyin",
        core.cookieEnvelope("douyin", await sess.cookies.get({})),
      ),
    );
    const ffmpeg = path.join(
        tools(),
        process.platform === "win32" ? "ffmpeg.exe" : "ffmpeg",
      ),
      ffprobe = path.join(
        tools(),
        process.platform === "win32" ? "ffprobe.exe" : "ffprobe",
      );
    const input = path.join(dir, "源视频.mp4"),
      output = path.join(dir, "导出视频.mp4");
    const generated = spawnSync(
      ffmpeg,
      [
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=blue:s=1280x720:r=10",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=44100",
        "-t",
        "2",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        input,
      ],
      { windowsHide: true, encoding: "utf8" },
    );
    record(
      "bundled FFmpeg runs and creates real media",
      generated.status === 0,
    );
    const [command, prefix] = worker(),
      events = [];
    const runner = new Runner(command, prefix, { POCKET_TOOLS: tools() }, (e) =>
      events.push(e),
    );
    const done = await runner.run([
      "convert",
      "--input",
      input,
      "--output",
      output,
      "--quality",
      "480",
    ]);
    record(
      "packaged Python worker returns a real completion",
      done.terminal?.event === "converted" && fs.existsSync(output),
    );
    const parsed = JSON.parse(
      spawnSync(
        ffprobe,
        ["-v", "error", "-show_streams", "-show_format", "-of", "json", output],
        { windowsHide: true, encoding: "utf8" },
      ).stdout,
    );
    record(
      "480P respects aspect ratio",
      parsed.streams.some(
        (s) => s.codec_type === "video" && s.width === 854 && s.height === 480,
      ),
    );
    record(
      "output audio preserved",
      parsed.streams.some((s) => s.codec_type === "audio"),
    );
    record(
      "export has genuine progress events",
      events.some((e) => e.event === "progress"),
    );
    const r = {
      id: "media-test",
      path: output,
      link: "https://www.douyin.com/video/1234567890123456789",
      title: "本地隔离视频",
      author: "测试",
      platform: "douyin",
      mediaKind: "video",
      videoID: "1234567890123456789",
    };
    library.update((d) => d.records.push(r));
    const url = mediaURL(output);
    const range = await win.webContents.executeJavaScript(
      `fetch(${JSON.stringify(url)},{headers:{Range:'bytes=0-31'}}).then(async r=>({status:r.status,size:(await r.arrayBuffer()).byteLength}))`,
    );
    record(
      "packaged media protocol handles byte-range seeking",
      range.status === 206 && range.size === 32,
    );
    const loaded = await win.webContents.executeJavaScript(
      `new Promise(resolve=>{const video=document.createElement('video');video.src=${JSON.stringify(url)};video.muted=true;document.body.append(video);video.onloadedmetadata=()=>resolve(video.duration>1&&video.videoWidth===854);video.onerror=()=>resolve(false);setTimeout(()=>resolve(false),8000);})`,
    );
    record("renderer decodes real packaged media", loaded);
    await win.webContents.executeJavaScript("navigate('records')");
    await win.webContents.executeJavaScript(
      "document.querySelector('.record-cover').click();new Promise(r=>setTimeout(r,500))",
    );
    record(
      "whole cover is clickable and expands the local video",
      await win.webContents.executeJavaScript(
        "document.querySelector('.record-cover').tagName==='BUTTON' && document.querySelector('.record-cover').getBoundingClientRect().width===104 && !!document.querySelector('.inline-player')",
      ),
    );
    await win.webContents.executeJavaScript(
      "document.querySelector('.record-cover').click()",
    );
    record(
      "same cover control releases and retracts playback",
      await win.webContents.executeJavaScript(
        "!document.querySelector('.inline-player') && document.querySelector('[data-video-glyph]').textContent==='▶'",
      ),
    );
    const missing = path.join(dir, "missing", "folder");
    const browsed = await win.webContents.executeJavaScript(
      `window.shiying.call('folder-list',{path:${JSON.stringify(missing)},fallback:true})`,
    );
    record(
      "initial folder browser opens nearest existing parent without creating paths",
      browsed.path === dir && !fs.existsSync(missing),
    );
    const articleDir = path.join(dir, "文章"),
      images = path.join(articleDir, "images");
    fs.mkdirSync(images, { recursive: true });
    const picture = path.join(images, "001.png");
    const png = spawnSync(
      ffmpeg,
      ["-v", "error", "-i", output, "-frames:v", "1", picture],
      { windowsHide: true, encoding: "utf8" },
    );
    record("article fixture has a genuine decoded image", png.status === 0);
    const html = path.join(articleDir, "文章.html");
    fs.writeFileSync(
      html,
      '<!doctype html><meta charset="utf-8"><h1>离线测试</h1><img src="images/001.png">',
    );
    library.update((d) =>
      d.articles.push({
        id: "article-test",
        path: articleDir,
        htmlPath: html,
        coverPath: picture,
        title: "完整标题".repeat(20),
        account: "测试公众号",
        excerpt: "正文".repeat(50),
        published: "2026-10-12",
        characters: 100,
        imageCount: 1,
        date: new Date().toISOString(),
      }),
    );
    await win.webContents.executeJavaScript("navigate('articles')");
    record(
      "article link input keeps internal scrolling in a compact horizontal row",
      await win.webContents.executeJavaScript(
        "document.querySelector('#articleLinks').getBoundingClientRect().height<=38 && getComputedStyle(document.querySelector('#articleLinks')).overflowY==='auto'",
      ),
    );
    record(
      "article cards share the compact cover and two-line excerpt",
      await win.webContents.executeJavaScript(
        "document.querySelector('.article-cover').getBoundingClientRect().width===104 && document.querySelector('.article-excerpt').textContent.endsWith('...') && !document.querySelector('.article-tile .read')",
      ),
    );
    const articleURL = mediaURL(html);
    const assets = await win.webContents.executeJavaScript(
      `fetch(${JSON.stringify(articleURL.replace(encodeURIComponent("文章.html"), "images/001.png"))}).then(async r=>({status:r.status,size:(await r.arrayBuffer()).byteLength}))`,
    );
    record(
      "offline article protocol serves local original images",
      assets.status === 200 && assets.size > 100,
    );
    const denied = await win.webContents.executeJavaScript(
      `fetch(${JSON.stringify(url.replace(encodeURIComponent(path.basename(output)), encodeURIComponent(path.basename(input))))}).then(r=>r.status)`,
    );
    record(
      "video token cannot expose another file in the same folder",
      denied === 404,
    );
    fs.mkdirSync(path.dirname(report), { recursive: true });
    await win.webContents.executeJavaScript(
      "new Promise(r=>setTimeout(r,500))",
    );
    const shot = await win.webContents.capturePage();
    fs.writeFileSync(report.replace(/\.json$/, ".png"), shot.toPNG());
    // Exercise the actual main-process IPC and renderer with synthetic image bytes.
    ctx.setCoverFixture(picture);
    await win.webContents.executeJavaScript("navigate('single')");
    record("both capture areas default to video only", await win.webContents.executeJavaScript("document.querySelector('#singleVideo').checked&&!document.querySelector('#singleCover').checked&&document.querySelector('#creatorVideo').checked&&!document.querySelector('#creatorCover').checked"));
    await win.webContents.executeJavaScript("document.querySelector('#singleVideo').click()");
    record("empty selection disables preview and download", await win.webContents.executeJavaScript("document.querySelector('#preview').disabled&&document.querySelector('#download').disabled"));
    await win.webContents.executeJavaScript("document.querySelector('#singleCover').click()");
    record("cover-only hides video quality controls", await win.webContents.executeJavaScript("document.querySelector('#singleQuality').hidden&&!document.querySelector('#preview').disabled"));
    const beforeCovers = library.state.records.length;
    await win.webContents.executeJavaScript("document.querySelector('#singleLink').value='https://www.douyin.com/video/7695364508945111030';window.shiying.call('task',{kind:'info',link:document.querySelector('#singleLink').value,selection:{video:false,cover:true}})");
    await win.webContents.executeJavaScript("new Promise(r=>setTimeout(r,250))");
    let d = (await ctx.state()).draft, temporary = d.imagePaths.slice();
    record("single-cover preview is local and uncommitted", d.kind === "video_cover" && temporary.length === 1 && library.state.records.length === beforeCovers && fs.existsSync(temporary[0]));
    record("cover confirm and cancel remain visible in the fixed footer",await win.webContents.executeJavaScript("document.querySelector('#savePhotos').closest('footer')&&document.querySelector('#cancelPhotos').closest('footer')&&!document.querySelector('#savePhotos').hidden&&document.querySelector('#savePhotos').getBoundingClientRect().bottom<=innerHeight"));
    record("cover image exposes right-click copy", await win.webContents.executeJavaScript("typeof document.querySelector('#draftImages img').oncontextmenu==='function'"));
    if (process.platform === "win32") await win.webContents.executeJavaScript(`window.shiying.call('photo-copy',{path:${JSON.stringify(temporary[0])}})`);
    const singleShot=await win.webContents.capturePage();fs.writeFileSync(path.join(path.dirname(report),'windows-cover-single.png'),singleShot.toPNG());
    await win.webContents.executeJavaScript("window.shiying.call('photo-cancel')");
    if (process.platform === "win32") { const items=await require('electron').clipboard.read();const item=items.find((x)=>x.types.includes('image/png'));const blob=item?await item.getType('image/png'):null;record("copied cover remains full image bytes after cancellation",blob&&require('electron').nativeImage.createFromBuffer(Buffer.from(await blob.arrayBuffer())).getSize().width===854); }
    record("single cancel deletes original temporary cover and writes no record", temporary.every((p)=>!fs.existsSync(p)) && library.state.records.length === beforeCovers);
    const singleArgs={kind:"info",link:"https://www.douyin.com/video/7695364508945111030",selection:{video:false,cover:true}};
    await win.webContents.executeJavaScript(`window.shiying.call('task',${JSON.stringify(singleArgs)})`);
    d=(await ctx.state()).draft;temporary=d.imagePaths.slice();
    await win.webContents.executeJavaScript("new Promise(resolve=>{const timer=setInterval(()=>{if(document.querySelector('#draftImages img')&&!document.querySelector('#savePhotos').disabled){clearInterval(timer);resolve();}},25);setTimeout(()=>{clearInterval(timer);resolve();},5000)})");
    await win.webContents.executeJavaScript("document.querySelector('#draftImages img').click();new Promise(r=>setTimeout(r,200))");
    record("temporary image viewer offers confirm and cancel for its entire draft",await win.webContents.executeJavaScript("document.querySelector('#photoDialog').open&&!document.querySelector('#photoConfirm').hidden&&!document.querySelector('#photoCancel').hidden"));
    await win.webContents.executeJavaScript("document.querySelector('#photoConfirm').click();new Promise(r=>setTimeout(r,200))");
    const singleSaved=library.state.records[0];
    record("single confirm preserves original image and commits cover kind", singleSaved.mediaKind === "video_cover" && fs.existsSync(singleSaved.imagePaths[0]) && temporary.every((p)=>!fs.existsSync(p)) && !singleSaved.audioPath);
    await win.webContents.executeJavaScript(`window.shiying.call('task',${JSON.stringify(singleArgs)})`);
    temporary=(await ctx.state()).draft.imagePaths.slice();
    await win.webContents.executeJavaScript("navigate('creator')");
    record("leaving single download removes its unconfirmed cover", temporary.every((p)=>!fs.existsSync(p)) && !(await ctx.state()).draft);
    await win.webContents.executeJavaScript("document.querySelector('#creatorVideo').click();document.querySelector('#creatorCover').click()");
    const chosen=[{id:"7695364508945111031",title:"博主封面一",author:"测试",link:"https://www.douyin.com/video/7695364508945111031",isVideo:true},{id:"7695364508945111032",title:"博主封面二",author:"测试",link:"https://www.douyin.com/video/7695364508945111032",isVideo:true}];
    const creatorArgs={kind:"creator-covers",posts:chosen,collectionID:c.id,homepage:"https://www.douyin.com/user/isolated-fixture",selection:{video:false,cover:true}};
    await win.webContents.executeJavaScript(`document.querySelector('#startDateEnabled').checked=false;document.querySelector('#endDateEnabled').checked=false;posts=${JSON.stringify(chosen)};selected=new Set(posts.map(p=>p.id));document.querySelector('#creatorCollection').value=${JSON.stringify(c.id)};renderPosts()`);
    await win.webContents.executeJavaScript("document.querySelector('#downloadPosts').click();new Promise(r=>setTimeout(r,500))");
    d=(await ctx.state()).draft;temporary=d.imagePaths.slice();
    await win.webContents.executeJavaScript("new Promise(r=>setTimeout(r,250))");
    const creatorShot=await win.webContents.capturePage();fs.writeFileSync(path.join(path.dirname(report),'windows-cover-creator.png'),creatorShot.toPNG());
    record("creator two-cover preview is frozen and does not enqueue video", d.owner === "creator" && temporary.length === 2 && library.state.queue.length === 0);
    await win.webContents.executeJavaScript("window.shiying.call('photo-cancel')");
    record("creator cancel removes the whole temporary group", temporary.every((p)=>!fs.existsSync(p)));
    await win.webContents.executeJavaScript(`window.shiying.call('task',${JSON.stringify(creatorArgs)})`);
    temporary=(await ctx.state()).draft.imagePaths.slice();
    await win.webContents.executeJavaScript("window.shiying.call('photo-save')");
    const group=library.state.records.slice(0,2);
    record("creator confirm saves all images in selected collection atomically", group.every((r)=>r.mediaKind === "video_cover"&&r.collectionID===c.id&&fs.existsSync(r.imagePaths[0]))&&temporary.every((p)=>!fs.existsSync(p)));
    const together={...creatorArgs,posts:[{...chosen[0],id:"7695364508945111033",link:"https://www.douyin.com/video/7695364508945111033"}],selection:{video:true,cover:true}};
    await win.webContents.executeJavaScript(`window.shiying.call('task',${JSON.stringify(together)})`);
    record("both selections defer video queue until cover confirmation",library.state.queue.length===0);
    await win.webContents.executeJavaScript("window.shiying.call('photo-save')");
    record("both selections save cover then enqueue exactly the frozen video",library.state.queue.length===1&&library.state.queue[0].videoID===together.posts[0].id&&library.state.queue[0].status==='pending');
    library.update((state)=>{state.queue=[];});
    await win.webContents.executeJavaScript(`window.shiying.call('task',${JSON.stringify(creatorArgs)})`);
    temporary=(await ctx.state()).draft.imagePaths.slice();
    await win.webContents.executeJavaScript("navigate('records')");
    record("leaving creator page cleans every unconfirmed cover",temporary.every((p)=>!fs.existsSync(p)));
    record("saved cover opens an image viewer instead of a video player",await win.webContents.executeJavaScript("document.querySelector('.record-cover').click();new Promise(r=>setTimeout(()=>r(document.querySelector('#photoDialog').open&&!document.querySelector('.inline-player')),200))"));
    await win.webContents.executeJavaScript("document.querySelector('#photoDialog').close()");
    ctx.setCoverFixture(null);
    const invalidJob=ctx.coverStore.create(), invalidInput=path.join(invalidJob,'input.json');
    fs.writeFileSync(invalidInput,JSON.stringify({id:'invalid',link:'https://unrelated.invalid/',cover:'https://unrelated.invalid/image.png'}));
    let invalidCover=false;try{await new Runner(command,prefix,{POCKET_TOOLS:tools()}).run(['cover','--input',invalidInput,'--folder',invalidJob]);}catch(e){invalidCover=e.message.includes('封面')||e.message.includes('链接');}
    ctx.coverStore.discard(invalidJob);
    record("actual packaged cover worker loads and rejects unsupported source",invalidCover);
    record("confirmed cover records survive a cold library read",new core.Library(dataRoot).state.records.filter((r)=>r.mediaKind==='video_cover').every((r)=>fs.existsSync(r.imagePaths[0])));
    const copySource = path.join(dir, "复制图片.webp");
    fs.copyFileSync(
      path.join(__dirname, "tests", "clipboard.webp"),
      copySource,
    );
    library.update((d) =>
      d.records.push({
        id: "copy-test",
        path: copySource,
        imagePaths: [copySource],
        mediaKind: "image_album",
      }),
    );
    const decoded = await new (require("./covers.cjs").Covers)(
      path.join(dataRoot, "copy-cache"),
      tools,
    ).image(copySource);
    record(
      "WebP clipboard path decodes a complete lossless image",
      !decoded.isEmpty() &&
        decoded.getSize().width === 8 &&
        decoded.getSize().height === 8,
    );
    if (process.platform === "win32") {
      const copied = await win.webContents.executeJavaScript(
        `window.shiying.call('photo-copy',{path:${JSON.stringify(copySource)}})`,
      );
      const items = await require("electron").clipboard.read();
      const item = items.find((x) => x.types.includes("image/png"));
      const blob = item ? await item.getType("image/png") : null;
      const image = require("electron").nativeImage.createFromBuffer(
        blob ? Buffer.from(await blob.arrayBuffer()) : Buffer.alloc(0),
      );
      record(
        "Windows native clipboard receives full image bytes",
        copied && !image.isEmpty() && image.getSize().width === 8,
      );
    }
    let stopped = false;
    try {
      await runner.run(["info", "--link", "https://unrelated.invalid/"]);
    } catch {
      stopped = true;
    }
    record("unsupported source cannot claim success", stopped);
    const marker = path.join(dataRoot, "runner-cancel-control");
    fs.mkdirSync(marker);
    const long = path.join(marker, "长视频.mp4");
    const made = spawnSync(
      ffmpeg,
      [
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=blue:s=1920x1080:r=30",
        "-t",
        "15",
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-pix_fmt",
        "yuv420p",
        long,
      ],
      { windowsHide: true, encoding: "utf8" },
    );
    record("cancellation fixture generated", made.status === 0);
    let canceled = false;
    const waiting = runner.run([
      "convert",
      "--input",
      long,
      "--output",
      path.join(marker, "取消结果.mp4"),
      "--quality",
      "480",
    ]);
    setTimeout(() => runner.cancel(), 25);
    try {
      await waiting;
    } catch {
      canceled = true;
    }
    record("own worker cancellation exits promptly", canceled && !runner.child);
    await require('./parity-checks.cjs').parityChecks(ctx,{record,output,picture,report,c});
    ctx.setCoverFixture(picture);
    const pendingClose = win.webContents.executeJavaScript(`window.shiying.call('task',${JSON.stringify(singleArgs)})`).catch(()=>{});
    await new Promise((resolve)=>setTimeout(resolve,10));
    await ctx.shutdownOwned(); await pendingClose;
    record("closing during capture waits for the task and clears only owned previews", !(await ctx.state()).draft && fs.readdirSync(ctx.coverStore.root).length === 0);
    const payload = {
      passed: true,
      version: app.getVersion(),
      platform: process.platform,
      architecture: process.arch,
      packaged: app.isPackaged,
      provenance: app.isPackaged
        ? JSON.parse(
            fs.readFileSync(
              path.join(
                process.resourcesPath,
                "Licenses",
                "build-provenance.json",
              ),
            ),
          )
        : null,
      checks,
    };
    fs.mkdirSync(path.dirname(report), { recursive: true });
    fs.writeFileSync(report, JSON.stringify(payload, null, 2));
    console.log("SHIYING_DESKTOP_SELF_TEST_PASS " + checks.length);
    if (!process.argv.includes("--self-test-keep-open")) app.exit(0);
    else win.show();
  } catch (error) {
    fs.mkdirSync(path.dirname(report), { recursive: true });
    fs.writeFileSync(
      report,
      JSON.stringify(
        {
          passed: false,
          platform: process.platform,
          packaged: app.isPackaged,
          error: error.message,
          checks,
        },
        null,
        2,
      ),
    );
    console.error("SHIYING_DESKTOP_SELF_TEST_FAILED " + error.message);
    app.exit(1);
  }
}
module.exports = { selfTest };
