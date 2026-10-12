"use strict";
const test = require("node:test"),
  assert = require("node:assert/strict"),
  fs = require("node:fs"),
  os = require("node:os"),
  path = require("node:path");
const core = require("../core.cjs");
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "shiying-core-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const lib = new core.Library(root);
  lib.update((d) => (d.settings.folder = path.join(root, "资料")));
  return { root, lib };
}
test("exact login origins reject credentials, HTTP and unrelated Tencent hosts", () => {
  for (const u of [
    "https://yuanbao.tencent.com/",
    "https://channels.weixin.qq.com/",
    "https://mp.weixin.qq.com/s/test",
  ])
    assert(core.allowedNavigation(u, "wechat"));
  for (const u of [
    "http://yuanbao.tencent.com/",
    "https://mail.tencent.com/",
    "https://yuanbao.tencent.com.evil.invalid",
    "https://user:pass@yuanbao.tencent.com/",
    "https://foo.yuanbao.tencent.com/",
  ])
    assert(!core.allowedNavigation(u, "wechat"));
  assert(!core.allowedNavigation("https://www.bilibili.com/", "douyin"));
});
test("cookie export narrows only known Tencent parser credentials and rejects stale/unrelated cookies", () => {
  const rows = [
    { name: "hy_user", value: "test-user", domain: ".tencent.com" },
    { name: "hy_token", value: "test-token", domain: ".tencent.com" },
    { name: "unrelated", value: "test", domain: ".tencent.com" },
    {
      name: "expired",
      value: "test",
      domain: "yuanbao.tencent.com",
      expirationDate: 1,
    },
  ];
  const v = core.cookieEnvelope("wechat", rows, 100);
  assert.equal(v.cookies.length, 2);
  assert(v.cookies.every((c) => c.domain === "yuanbao.tencent.com"));
  assert(core.hasSession("wechat", v));
  assert.equal(core.cookieEnvelope("douyin", rows).length, 0);
});
test("Windows filename components handle reserved names and trailing dots", () => {
  assert.equal(core.component("CON"), "_CON");
  assert.equal(core.component("nul.txt"), "_nul.txt");
  assert.equal(core.component("标题:*?<>|. "), "标题______");
});
test("corrupt library remains untouched and blocks writes", (t) => {
  const { root } = fixture(t),
    file = path.join(root, "library.json");
  fs.writeFileSync(file, "broken");
  const lib = new core.Library(root);
  assert(lib.blocked);
  assert.throws(() => lib.create("test"));
  assert.equal(fs.readFileSync(file, "utf8"), "broken");
});
test("real folder move relocates media and restores durable records after restart", (t) => {
  const { root, lib } = fixture(t);
  const a = lib.create("甲", null, "观察标题"),
    b = lib.create("乙");
  const p = path.join(a.path, "视频 #1.mp4");
  fs.writeFileSync(p, "same bytes");
  lib.update((d) =>
    d.records.push({ id: "r", path: p, imagePaths: [p], collectionID: a.id }),
  );
  lib.move(a.id, b.id);
  const after = new core.Library(root);
  after.recoverMove();
  assert.equal(after.collection(a.id).parentID, b.id);
  assert.equal(
    fs.readFileSync(after.state.records[0].path, "utf8"),
    "same bytes",
  );
  assert.equal(after.collection(a.id).notes, "观察标题");
  assert(!fs.existsSync(path.join(root, "move-journal.json")));
});
test("folder conflict and descendant moves preserve original data", (t) => {
  const { lib } = fixture(t);
  const a = lib.create("甲"),
    b = lib.create("乙"),
    child = lib.create("子", a.id);
  fs.mkdirSync(path.join(b.path, a.name));
  assert.throws(() => lib.move(a.id, b.id));
  assert(fs.existsSync(a.path));
  assert.throws(() => lib.move(a.id, child.id));
});
test("crash recovery returns a physically renamed folder to old saved state", (t) => {
  const { root, lib } = fixture(t);
  const a = lib.create("甲"),
    b = lib.create("乙"),
    dest = path.join(b.path, a.name);
  core.atomicWrite(path.join(root, "move-journal.json"), {
    id: a.id,
    old: a.path,
    dest,
    parentID: b.id,
  });
  fs.renameSync(a.path, dest);
  const recovered = new core.Library(root);
  recovered.recoverMove();
  assert(fs.existsSync(a.path));
  assert(!fs.existsSync(dest));
  assert(!recovered.blocked);
});
test("queue deduplication is collection scoped, over-limit never truncates", (t) => {
  const { lib } = fixture(t),
    a = lib.create("甲"),
    b = lib.create("乙"),
    link = "https://www.douyin.com/video/1234567890123456789";
  assert.equal(lib.enqueue(link + "\n" + link, a.id), 1);
  assert.equal(lib.enqueue(link, b.id), 1);
  assert.throws(() => lib.enqueue(Array(5001).fill(link).join("\n"), a.id));
  assert.equal(lib.state.queue.length, 2);
});
test("restart does not automatically run an unfinished queue", (t) => {
  const { root, lib } = fixture(t);
  lib.update((d) => d.queue.push({ id: "q", status: "running" }));
  const after = new core.Library(root);
  assert.equal(after.state.queue[0].status, "pending");
});
test("unknown statistics never become false zeros or changes", () => {
  assert.deepEqual(
    core.deltas({ likes: null, comments: 0 }, { likes: 10, comments: 2 }),
    [{ key: "comments", before: 0, after: 2, delta: 2 }],
  );
  assert.deepEqual(core.deltas({ likes: 8 }, { likes: null }), []);
});
test("media ranges support seeking and reject malformed/multiple/out-of-file ranges", () => {
  assert.deepEqual(core.rangeHeader("bytes=2-5", 10), {
    start: 2,
    end: 5,
    status: 206,
  });
  assert.deepEqual(core.rangeHeader("bytes=-3", 10), {
    start: 7,
    end: 9,
    status: 206,
  });
  for (const x of ["bytes=12-20", "bytes=4-2", "bytes=0-1,4-5", "bytes=-"])
    assert.equal(core.rangeHeader(x, 10), null);
});
test("filters retain exact date window and fail closed for missing numbers", () => {
  const rows = [
    {
      id: "a",
      link: "https://test.invalid",
      publishedAt: Date.parse("2026-10-12T12:00:00+08:00") / 1000,
      diggCount: 10,
    },
    { id: "b", link: "https://test.invalid", diggCount: null },
  ];
  assert.deepEqual(
    core
      .filteredPosts(rows, { start: "2026-10-12", end: "2026-10-12", likes: 5 })
      .map((p) => p.id),
    ["a"],
  );
});
test("strict Gregorian dates reject normalized and reversed windows", () => {
  for (const x of [
    "2026-02-29",
    "2026-13-01",
    "2026-04-31",
    "1969-12-31",
    "2026-1-1",
  ])
    assert(!core.validDate(x));
  assert(core.validDate("2024-02-29"));
  assert.throws(() =>
    core.filteredPosts([], { start: "2026-10-12", end: "2026-10-11" }),
  );
});
test("creator fields use worker createdAt and strict interaction thresholds", () => {
  const rows = [
    {
      id: "a",
      isVideo: true,
      link: "https://test.invalid",
      createdAt: Date.parse("2026-10-12T23:59:59+08:00") / 1000,
      diggCount: 15000,
      collectCount: 2,
    },
    {
      id: "b",
      isVideo: true,
      link: "https://test.invalid",
      createdAt: Date.parse("2026-10-12T00:00:00+08:00") / 1000,
      diggCount: 15001,
      collectCount: 8,
    },
    {
      id: "photo",
      isVideo: false,
      link: "https://test.invalid",
      diggCount: 999999,
    },
  ];
  assert.deepEqual(
    core
      .filteredPosts(rows, {
        start: "2026-10-12",
        end: "2026-10-12",
        likes: 15000,
      })
      .map((r) => r.id),
    ["b"],
  );
  assert.deepEqual(
    core.filteredPosts(rows, { sort: "collects" }).map((r) => r.id),
    ["b", "a"],
  );
});
test("cover URLs only grant HTTPS access to known platform CDN domains", () => {
  assert.equal(
    core.approvedCover("http://i0.hdslb.com/test.jpg"),
    "https://i0.hdslb.com/test.jpg",
  );
  for (const u of [
    "https://qpic.cn.evil.invalid/a",
    "https://user:pass@qpic.cn/a",
    "file:///tmp/a",
    "https://qpic.cn:444/a",
  ])
    assert.equal(core.approvedCover(u), null);
});
test("article snippets preserve fifty graphemes and mark overflow", () => {
  const family = "👨‍👩‍👧‍👦";
  assert.equal(core.excerpt(family.repeat(51)), family.repeat(50) + "...");
  assert.equal(core.excerpt(" 短 文 "), "短 文");
});
test("folder moves also update offline article cover and HTML references", (t) => {
  const { lib } = fixture(t);
  const a = lib.create("甲"),
    b = lib.create("乙"),
    html = path.join(a.path, "文章.html"),
    cover = path.join(a.path, "cover.png");
  fs.writeFileSync(html, "html");
  fs.writeFileSync(cover, "png");
  lib.update((d) =>
    d.articles.push({
      id: "article",
      path: a.path,
      htmlPath: html,
      coverPath: cover,
    }),
  );
  lib.move(a.id, b.id);
  assert(fs.existsSync(lib.state.articles[0].htmlPath));
  assert(fs.existsSync(lib.state.articles[0].coverPath));
});
test("creator enqueue is uncapped by text-import rows and freezes provenance", (t) => {
  const { lib } = fixture(t),
    a = lib.create("甲"),
    homepage = "https://www.douyin.com/user/test";
  const posts = Array.from({ length: 5001 }, (_, n) => ({
    id: String(1234567890123400000n + BigInt(n)),
    link:
      "https://www.douyin.com/video/" +
      String(1234567890123400000n + BigInt(n)),
    isVideo: true,
  }));
  assert.equal(lib.enqueuePosts(posts, a.id, homepage), 5001);
  assert.equal(lib.state.queue[0].creatorSourceURL, homepage);
  assert.equal(lib.enqueuePosts(posts.slice(0, 1), a.id, homepage), 0);
});
test("real worker statistic schema maps numeric and approximate public values", () => {
  const a = core.normalizeStatistics({
      likeCount: 8,
      commentCount: 0,
      collectCount: null,
      viewCount: null,
      shareCount: null,
      displayCounts: { share: "1.5万" },
    }),
    b = core.normalizeStatistics({
      likeCount: 10,
      commentCount: 1,
      collectCount: null,
    });
  assert.equal(a.likes, 8);
  assert.equal(a.shares, null);
  assert.equal(a.sharesText, "1.5万");
  assert.deepEqual(
    core.deltas(a, b).map((d) => d.key),
    ["likes", "comments"],
  );
});
test("statistics request canonicalizes copied share text and preserves creator source", () => {
  const key = core.statisticKey({
    platform: "douyin",
    videoID: "1234567890123456789",
    link: "复制此分享 https://v.douyin.com/test/ 打开",
    creatorSourceURL: "https://www.douyin.com/user/test",
  });
  assert.equal(key.link, "https://www.douyin.com/video/1234567890123456789");
  assert.equal(key.homepage, "https://www.douyin.com/user/test");
});
test("download completion stores the queue and record in one durable snapshot", (t) => {
  const { root, lib } = fixture(t),
    a = lib.create("学习");
  lib.enqueue(
    "https://www.douyin.com/video/1234567890123456789",
    a.id,
    "highest",
    true,
  );
  const q = lib.state.queue[0];
  lib.complete(
    {
      id: "saved",
      title: "视频",
      collectionID: a.id,
      path: path.join(a.path, "sample.mp4"),
      mediaKind: "video",
    },
    q.id,
  );
  const reread = new core.Library(root);
  assert.equal(reread.state.queue[0].status, "completed");
  assert.equal(reread.state.queue[0].recordID, reread.state.records[0].id);
  assert.match(reread.state.records[0].audioError, /音轨/);
});

test("article retries and interruptions retain saved bodies and never duplicate links", (t) => {
  const { lib } = fixture(t),
    link = "https://mp.weixin.qq.com/s/test";
  lib.articleEvent({ event: "article_progress", link });
  lib.articleEvent({
    event: "article_failure",
    link,
    message: "network unavailable",
  });
  assert.equal(lib.state.articles[0].status, "failed");
  lib.articleEvent({ event: "article_progress", link });
  lib.articleEvent({
    event: "article_saved",
    link,
    article: { path: "/test/article", title: "正文" },
  });
  const saved = lib.state.articles[0].htmlPath;
  lib.articleEvent({ event: "article_progress", link });
  lib.articleEvent({ event: "article_failure", link, message: "retry failed" });
  assert.equal(lib.state.articles[0].status, "saved");
  assert.equal(lib.state.articles[0].htmlPath, saved);
  lib.articleEvent({ event: "article_progress", link });
  lib.endArticles();
  assert.equal(lib.state.articles[0].attemptStatus, "failed");
  assert.equal(lib.state.articles[0].htmlPath, saved);
  lib.articleEvent({ event: "article_progress", link: link + "2" });
  lib.endArticles();
  assert.equal(
    lib.state.articles.find((a) => a.link === link + "2").status,
    "failed",
  );
  assert.equal(lib.state.articles.filter((a) => a.link === link).length, 1);
});
