"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict");
const { projectURL, version, newer, parseRelease, ReleaseUpdates, interval } = require("../release-updates.cjs");
function release(v = "1.8.8", suffix = "Windows-x64-Setup.exe") {
  const name = `Shiying-${v}-${suffix}`, tag = `v${v}`;
  return { tag_name: tag, html_url: `${projectURL}/releases/tag/${tag}`, draft: false, prerelease: false,
    assets: [{ name, state: "uploaded", size: 123, browser_download_url: `${projectURL}/releases/download/${tag}/${name}` }] };
}
const ok = (value = release()) => new Response(JSON.stringify(value), { status: 200 });
test("numeric versions and stable-only tags", () => {
  assert(newer("v1.8.14", "1.8.9")); assert(newer("2.0.0", "1.99.999"));
  assert(!newer("1.8.7", "1.8.7")); assert(!newer("1.8.6", "1.8.7"));
  for (const v of ["1.8", "1.8.8-beta", "01.8.8", "1.8.8+1", "1.8.8\n", "9.9999999.0", null]) assert.equal(version(v), null);
});
test("correct repository and matching ready Windows installer only", () => {
  assert.equal(parseRelease(release()).version, "1.8.8");
  assert(parseRelease(release("1.8.8", "Windows-x64.zip")).downloadURL.endsWith(".zip"));
  for (const mutate of [
    r => r.draft = true, r => r.prerelease = true, r => delete r.draft,
    r => r.tag_name = "v1.8.8-beta", r => r.html_url += "?redirect=evil",
    r => r.html_url = r.html_url.replace("github.com", "github.com.evil.test"),
    r => r.assets = [], r => r.assets[0].size = 0, r => r.assets[0].state = "new",
    r => r.assets[0].browser_download_url = "https://evil.test/setup.exe",
    r => r.assets[0].browser_download_url = r.assets[0].browser_download_url.replace("v1.8.8", "v1.8.7"),
    r => r.assets[0].name = "Shiying-1.8.8-Mac-arm64.dmg",
  ]) { const value = release(); mutate(value); assert.throws(() => parseRelease(value)); }
});
test("startup, periodic, manual cooldown and concurrent checks", async () => {
  let now = 1000000, calls = 0, changes = 0;
  const u = new ReleaseUpdates("1.8.7", { now: () => now, fetchLatest: async () => { calls++; return ok(); }, onChange: () => changes++ });
  const a = u.check(); assert.equal(u.state.checking, true); assert.equal(u.check(true), a);
  await a; assert.equal(calls, 1); assert.equal(changes, 2); assert.equal(u.state.available.version, "1.8.8");
  await u.check(true); now += 60001; await u.check(); assert.equal(calls, 1);
  await u.check(true); assert.equal(calls, 2);
  now += interval; await u.check(); assert.equal(calls, 3);
});
test("current and locally newer versions do not offer a downgrade", async () => {
  for (const current of ["1.8.8", "1.8.10"]) {
    const u = new ReleaseUpdates(current, { fetchLatest: async () => ok() }); await u.check();
    assert.equal(u.state.available, null); assert.equal(u.state.message, "当前版本已是最新");
  }
});
test("offline failure preserves discovered update and retries after an hour", async () => {
  let now = 1000000, calls = 0;
  const u = new ReleaseUpdates("1.8.7", { now: () => now, fetchLatest: () => { if (++calls === 2) throw Error("offline"); return ok(); } });
  await u.check(); now += 60001; await u.check(true);
  assert.equal(u.state.available.version, "1.8.8"); assert.match(u.state.message, /网络/);
  await u.check(true); assert.equal(calls, 2); assert.equal(u.pending, null);
  now += 3600001; await u.check(); assert.equal(calls, 3); assert.match(u.state.message, /发现新版/);
});
test("HTTP failure, invalid JSON, missing platform and rate limiting can recover", async () => {
  for (const response of [new Response("", { status: 404 }), new Response("invalid"), ok(release("1.8.8", "Mac-arm64.dmg"))]) {
    let now = 1000000, calls = 0;
    const u = new ReleaseUpdates("1.8.7", { now: () => now, fetchLatest: async () => { calls++; return calls === 1 ? response : ok(); } });
    await u.check(); assert.equal(u.state.available, null); assert.equal(u.state.checking, false);
    now += 3600001; await u.check(); assert.equal(u.state.available.version, "1.8.8");
  }
  let now = 1000000, calls = 0;
  const u = new ReleaseUpdates("1.8.7", { now: () => now, fetchLatest: async () => ++calls === 1 ? new Response("", { status: 429, headers: { "Retry-After": "7200" } }) : ok() });
  await u.check(); now += 3600001; await u.check(true); assert.equal(calls, 1);
  now += 3600000; await u.check(); assert.equal(calls, 2);
});
