"use strict";
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const core = require('./core.cjs');

function links(text) {
  text = String(text || '');
  if (Buffer.byteLength(text) > 5 * 1024 * 1024) throw Error('输入超过5 MiB，未截断');
  const found = text.match(/https?:\/\/[^\s<>"“”]+/gi) || [];
  const result = [], seen = new Set();
  for (let raw of found) {
    raw = raw.replace(/[，。；！!？?、）)\]】》]+$/, '');
    if (!core.detect(raw)) continue;
    const u = new URL(raw); u.hash = '';
    if (u.pathname.match(/\/video\/\d+|\/note\/\d+|\/sph\/[\w-]+|\/video\/BV[\w]+/)) u.search = '';
    const key = u.href;
    if (!seen.has(key)) { result.push(raw); seen.add(key); }
  }
  if (!result.length) throw Error('没有支持的作品链接');
  if (result.length > 200) throw Error('最多200条不同链接，未截断');
  return result;
}
function homepage(platform, id, raw) {
  let u; try { u = new URL(raw); } catch { throw Error('需要已经采集确认的博主主页'); }
  id = String(id || '');
  if (platform === 'douyin' && /^[\w-]{10,160}$/.test(id) && ['www.douyin.com','douyin.com'].includes(u.hostname) && u.pathname === '/user/' + id) return 'https://www.douyin.com/user/' + id;
  if (platform === 'bilibili' && /^\d+$/.test(id) && u.hostname === 'space.bilibili.com' && u.pathname.replace(/\/$/, '') === '/' + id) return 'https://space.bilibili.com/' + id;
  if (platform === 'xiaohongshu' && /^[a-f\d]{24}$/i.test(id) && ['www.xiaohongshu.com','xiaohongshu.com'].includes(u.hostname) && u.pathname === '/user/profile/' + id) return 'https://www.xiaohongshu.com/user/profile/' + id;
  throw Error(platform === 'wechat' ? '视频号暂不支持博主主页订阅' : '采集结果缺少稳定博主身份或主页不匹配');
}
function identity(r) {
  const platform = core.detect(r.link); if (!platform) return null;
  const id = r.videoID || new URL(r.link).pathname.match(/\/(?:video|note)\/([\w-]+)/)?.[1] || core.shareURL(r.link);
  return platform + ':' + String(id).replace(new RegExp('^'+platform+':'),'');
}
function known(library) {
  const set = new Set();
  for (const r of library.state.records) {
    if (r.mediaKind === 'video_cover' || !r.path || !fs.existsSync(r.path)) continue;
    const key = identity(r); if (key) set.add(key);
  }
  for (const q of library.state.queue) {
    if (!['pending','running'].includes(q.status)) continue;
    const key = identity(q); if (key) set.add(key);
  }
  return set;
}
function missing(posts, platform, existing) {
  const seen = new Set(existing);
  return posts.filter(p => {
    const key = identity({link:p.link, videoID:p.id});
    if (p.isVideo !== true || core.detect(p.link) !== platform || !key || seen.has(key)) return false;
    const u = new URL(p.link), value = u.pathname.match(/\/(?:video|note)\/([\w-]+)/)?.[1];
    if (['douyin','bilibili'].includes(platform) && value !== String(p.id).replace(/^bilibili:/,'')) return false;
    seen.add(key); return true;
  });
}
class Subscriptions {
  constructor(root) {
    this.file = path.join(root,'creator-subscriptions.json'); this.blocked = null; this.rows = []; this.expected = null;
    try {
      if (fs.existsSync(this.file)) {
        const stat=fs.lstatSync(this.file); if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 16*1024*1024) throw Error('订阅库文件类型或大小无效');
        this.expected=fs.readFileSync(this.file); const d=JSON.parse(this.expected);
        if(d.version!==1 || !Array.isArray(d.subscriptions)) throw Error('订阅库格式无效');
        this.validate(d.subscriptions); this.rows=d.subscriptions;
      }
    } catch(e) { this.blocked='订阅库无法读取，原文件保留：'+e.message; }
  }
  validate(rows) {
    if(rows.length>5000 || new Set(rows.map(x=>x.id)).size!==rows.length || new Set(rows.map(x=>x.platform+':'+x.creatorID)).size!==rows.length) throw Error('订阅数或唯一性无效');
    for(const r of rows) if(homepage(r.platform,r.creatorID,r.homepage)!==r.homepage || !r.name || Buffer.byteLength(r.name)>1024 || !['480','720','highest'].includes(r.quality) || !r.collectionID) throw Error('订阅字段无效');
  }
  update(fn) {
    if(this.blocked) throw Error(this.blocked);
    const lock=this.file+'.lock'; let fd;
    try {
      fd=fs.openSync(lock,'wx',0o600);
      const current=fs.existsSync(this.file)?fs.readFileSync(this.file):null;
      if((current===null)!==(this.expected===null) || current && !current.equals(this.expected)) throw Error('订阅库已被外部修改，请重新打开');
      const rows=structuredClone(this.rows); const result=fn(rows); this.validate(rows);
      core.atomicWrite(this.file,{version:1,subscriptions:rows});this.expected=fs.readFileSync(this.file);this.rows=rows;return result;
    } finally { if(fd!==undefined){fs.closeSync(fd);fs.unlinkSync(lock);} }
  }
  subscribe(data) {
    const home=homepage(data.platform,data.creatorID,data.homepage);
    return this.update(rows=> {
      const existing=rows.find(x=>x.platform===data.platform && x.creatorID===String(data.creatorID));
      const row={...existing,...data,id:existing?.id||crypto.randomUUID(),creatorID:String(data.creatorID),homepage:home,updatedAt:new Date().toISOString()};
      if(existing) Object.assign(existing,row); else rows.push(row);return row;
    });
  }
}
module.exports={links,homepage,identity,known,missing,Subscriptions};
