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
      await win.webContents.executeJavaScript(
        "document.querySelector('#version').textContent.includes('1.8.0')",
      ),
    );
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
