"use strict";
// Application releases are independent of creator subscriptions (updates.cjs).
const repository = "SJT-bright/shiying-media-workbench";
const projectURL = `https://github.com/${repository}`;
const latestURL = `https://api.github.com/repos/${repository}/releases/latest`;
const interval = 6 * 60 * 60 * 1000;
function version(raw) {
  if (typeof raw !== "string" || raw.trim() !== raw || !/^v?(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})$/.test(raw)) return null;
  return raw.replace(/^v/, "").split(".").map(Number);
}
function newer(remote, current) {
  const a = version(remote), b = version(current);
  if (!a || !b) throw Error("GitHub 版本号无效，稍后重试。");
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return false;
}
function parseRelease(value) {
  const parts = version(value?.tag_name);
  if (!parts || value.draft !== false || value.prerelease !== false ||
      value.html_url !== `${projectURL}/releases/tag/${value.tag_name}` || !Array.isArray(value.assets)) {
    throw Error("GitHub 发行信息不完整，稍后重试。");
  }
  const text = parts.join(".");
  for (const suffix of ["Windows-x64-Setup.exe", "Windows-x64.zip"]) {
    const name = `Shiying-${text}-${suffix}`;
    const url = `${projectURL}/releases/download/${value.tag_name}/${name}`;
    if (value.assets.some(a => a.name === name && a.browser_download_url === url && a.state === "uploaded" && Number.isSafeInteger(a.size) && a.size > 0)) {
      return { version: text, pageURL: value.html_url, downloadURL: url };
    }
  }
  throw Error("该版本尚未提供 Windows x64 安装包，稍后重试。");
}
async function fetchLatest() {
  const response = await fetch(latestURL, {
    headers: { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "Shiying-Update-Check" },
    signal: AbortSignal.timeout(30000), redirect: "error", credentials: "omit",
  });
  if (response.status !== 200) return response;
  // Bound the public metadata response before JSON parsing.
  const reader = response.body.getReader(); let size = 0; const chunks = [];
  try {
    for (;;) {
      const { done, value } = await reader.read(); if (done) break;
      size += value.length;
      if (size > 2 * 1024 * 1024) throw Error("GitHub 发行信息过大，稍后重试。");
      chunks.push(Buffer.from(value));
    }
  } finally { await reader.cancel(); }
  return new Response(Buffer.concat(chunks), { status: response.status, headers: response.headers });
}
class ReleaseUpdates {
  constructor(current, { fetchLatest: fetcher = fetchLatest, now = Date.now, onChange = () => {} } = {}) {
    this.current = current; this.fetcher = fetcher; this.now = now; this.onChange = onChange;
    this.state = { checking: false, available: null, message: "启动及每 6 小时自动检查" };
    this.lastAttempt = null; this.nextAutomatic = 0; this.retryAfter = 0; this.pending = null;
  }
  check(manual = false) {
    if (this.pending) return this.pending;
    const now = this.now();
    if (now < this.retryAfter || (this.lastAttempt !== null && now - this.lastAttempt < 60000) || (!manual && now < this.nextAutomatic)) return Promise.resolve(this.state);
    this.lastAttempt = now; this.nextAutomatic = now + interval;
    this.state.checking = true; this.state.message = "正在检查 GitHub…"; this.onChange();
    this.pending = (async () => {
      try {
        const response = await Promise.resolve().then(() => this.fetcher());
        if ([403, 429].includes(response.status)) {
          const reset = Number(response.headers.get("X-RateLimit-Reset")) * 1000;
          const rawDelay = response.headers.get("Retry-After");
          const delay = rawDelay && /^\d+$/.test(rawDelay) ? Number(rawDelay) * 1000 : Date.parse(rawDelay) - now;
          this.retryAfter = Math.max(now + Math.max(60000, Number.isFinite(delay) ? delay : 3600000), Number.isFinite(reset) ? reset : 0);
          throw Error("GitHub 请求次数受限，稍后会自动重试。");
        }
        if (response.status !== 200) throw Error(`GitHub 暂时无法访问（HTTP ${response.status}），稍后重试。`);
        const release = parseRelease(await response.json());
        this.state.available = newer(release.version, this.current) ? release : null;
        this.state.message = this.state.available ? `发现新版 ${release.version}` : "当前版本已是最新";
      } catch (error) {
        this.nextAutomatic = now + 3600000;
        this.state.message = error.message.startsWith("GitHub") || error.message.startsWith("该版本") ? error.message : "暂时无法检查更新，请检查网络后重试。";
      } finally { this.state.checking = false; this.pending = null; this.onChange(); }
      return this.state;
    })();
    return this.pending;
  }
  start() {
    if (this.timer) return;
    void this.check();
    this.timer = setInterval(() => void this.check(), 3600000); this.timer.unref?.();
  }
  stop() { clearInterval(this.timer); this.timer = null; }
}
module.exports = { repository, projectURL, latestURL, interval, version, newer, parseRelease, fetchLatest, ReleaseUpdates };
