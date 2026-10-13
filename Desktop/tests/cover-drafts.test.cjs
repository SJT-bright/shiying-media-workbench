"use strict";
const test = require("node:test"), assert = require("node:assert/strict"), fs = require("node:fs"), path = require("node:path"), os = require("node:os"), crypto = require("node:crypto");
const { CoverDrafts, selection, hash } = require("../cover-drafts.cjs");
const core = require("../core.cjs");
function setup(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "shiying-cover-check-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const library = new core.Library(root);
  library.update((d) => { d.settings.folder = path.join(root, "测试素材"); });
  return { root, store: new CoverDrafts(root), library, destination: path.join(root, "保存 封面") };
}
function draft(store, id = "one") {
  const job = store.create(), dir = path.join(job, "原图"); fs.mkdirSync(dir);
  const image = path.join(dir, "001.png"); fs.writeFileSync(image, "original image bytes " + id);
  return store.register(job, { mediaKind: "video_cover", imagePaths: [image], imageSHA256: hash(image), video: { id, title: id, author: "作者" } }, { link: "https://www.douyin.com/video/" + id });
}
const makeRecord = (d,e) => ({ id: crypto.randomUUID(), mediaKind: "video_cover", path: e.path, imagePaths: e.imagePaths, videoID: d.event.video.id });
test("old callers default to video; all three choices work; empty and nonboolean choices fail", () => {
  assert.deepEqual(selection(),{video:true,cover:false});
  for (const value of [{video:true,cover:false},{video:false,cover:true},{video:true,cover:true}]) assert.deepEqual(selection(value),value);
  assert.throws(()=>selection({video:false,cover:false})); assert.throws(()=>selection({video:"yes",cover:true}));
});
test("cancel removes the whole owned group but retains unrelated directories", (t) => {
  const {store}=setup(t), a=draft(store), b=draft(store,"two"), unknown=path.join(store.root,"unknown");fs.mkdirSync(unknown);
  store.discard(a.job);store.discard(b.job);
  assert(!fs.existsSync(a.imagePaths[0]));assert(!fs.existsSync(b.job));assert(fs.existsSync(unknown));
});
test("bad ownership and symlink jobs cannot delete other files",(t)=>{
  const {store}=setup(t), a=draft(store);fs.writeFileSync(path.join(a.job,'.shiying-photo-owner'),'wrong');
  assert.throws(()=>store.discard(a.job));assert(fs.existsSync(a.imagePaths[0]));
});
test("worker cannot register files outside its own job or with a wrong hash",(t)=>{
  const {store,root}=setup(t),job=store.create(),outside=path.join(root,'outside.png');fs.writeFileSync(outside,'bytes');
  assert.throws(()=>store.register(job,{mediaKind:'video_cover',imagePaths:[outside],imageSHA256:hash(outside)}));
  const a=draft(store);assert.throws(()=>store.register(a.job,{...a.event,imageSHA256:'0'.repeat(64)}));
});
test("confirm commits all covers once and clears temporary originals",(t)=>{
  const {store,destination,library}=setup(t), a=draft(store), b=draft(store,'two');let count=0;
  const records=store.save([a,b],destination,makeRecord,(records)=>{count++;library.update((d)=>d.records.unshift(...records));});
  assert.equal(count,1);assert.equal(records.length,2);assert(records.every((r)=>fs.existsSync(r.imagePaths[0])));assert(!fs.existsSync(a.job));assert(!fs.existsSync(b.job));assert(!fs.existsSync(store.journal));
  assert.equal(new core.Library(library.root || path.dirname(library.file)).state.records.length,2);
});
test("failed library commit rolls back every new image and keeps temporary originals for retry",(t)=>{
  const {store,destination}=setup(t),a=draft(store),b=draft(store,'two');
  assert.throws(()=>store.save([a,b],destination,makeRecord,()=>{throw Error('disk failed');}));
  assert.equal(fs.readdirSync(destination).length,0);assert(fs.existsSync(a.imagePaths[0]));assert(fs.existsSync(b.imagePaths[0]));
});
test("externally changed temporary images cannot be confirmed or silently deleted",(t)=>{
  const {store,destination}=setup(t),a=draft(store);fs.writeFileSync(a.imagePaths[0],'external modification');
  assert.throws(()=>store.save([a],destination,makeRecord,()=>{}));assert.throws(()=>store.discard(a.job));assert(fs.existsSync(a.imagePaths[0]));
});
test("same names receive separate destinations without overwriting",(t)=>{
  const {store,destination}=setup(t);const a=draft(store);let first=store.save([a],destination,makeRecord,()=>{})[0];
  const b=draft(store);let second=store.save([b],destination,makeRecord,()=>{})[0];assert.notEqual(first.path,second.path);assert.equal(hash(first.imagePaths[0]),hash(second.imagePaths[0]));
});
test("startup cleans abandoned owned preview jobs and ignores unowned directories",(t)=>{
  const {store,library}=setup(t),a=draft(store),unknown=path.join(store.root,crypto.randomUUID());fs.mkdirSync(unknown);
  store.recover(library);assert(!fs.existsSync(a.job));assert(fs.existsSync(unknown));
});
test("startup journal keeps already confirmed media and rolls back only its owned unconfirmed copy",(t)=>{
  const {store,destination,library}=setup(t);fs.mkdirSync(destination);
  const entries=['saved','unsaved'].map((n)=>{const d=path.join(destination,n);fs.mkdirSync(d);const id=crypto.randomUUID();fs.writeFileSync(path.join(d,'.shiying-cover-save-owner'),id);fs.writeFileSync(path.join(d,'001.png'),'bytes');return {destination:d,filename:'001.png',id,sha256:hash(path.join(d,'001.png'))};});
  library.update((d)=>d.records.push({id:entries[0].id,path:entries[0].destination}));core.atomicWrite(store.journal,{version:1,folder:destination,entries});store.recover(library);
  assert(fs.existsSync(path.join(entries[0].destination,'001.png')));assert(!fs.existsSync(entries[1].destination));assert(!fs.existsSync(store.journal));
});
test("recovery cannot remove an unknown directory with a forged ownership receipt",(t)=>{
  const {store,destination,library}=setup(t);fs.mkdirSync(destination);const d=path.join(destination,'unknown');fs.mkdirSync(d);fs.writeFileSync(path.join(d,'001.png'),'bytes');
  core.atomicWrite(store.journal,{version:1,folder:destination,entries:[{id:crypto.randomUUID(),destination:d,filename:'001.png',sha256:hash(path.join(d,'001.png'))}]});assert.throws(()=>store.recover(library));assert(fs.existsSync(d));assert(fs.existsSync(store.journal));
});
test("saving covers does not prevent the same works from entering the video queue",(t)=>{
  const {library}=setup(t), c=library.create('收藏',null,'');library.update((d)=>d.records.push({collectionID:c.id,videoID:'7695364508945111031',mediaKind:'video_cover'}));
  const post={id:'7695364508945111031',isVideo:true,link:'https://www.douyin.com/video/7695364508945111031'};
  assert.equal(library.enqueuePosts([post],c.id,'https://www.douyin.com/user/example'),1);assert.equal(library.enqueuePosts([post],c.id,'https://www.douyin.com/user/example'),0);
});

test("cleanup failure after commit reports saved and never presents a retryable unsaved transaction",(t)=>{
  const {store,destination,library}=setup(t),a=draft(store);const discard=store.discard.bind(store);store.discard=()=>{throw Error('open image handle');};
  const result=store.save([a],destination,makeRecord,(records)=>library.update((d)=>d.records.push(...records)));
  assert.equal(result.length,1);assert.equal(library.state.records.length,1);assert(store.cleanupWarning);assert(fs.existsSync(store.journal));
  assert.throws(()=>store.save([a],destination,makeRecord,()=>{}));store.discard=discard;store.recover(library);
  assert(fs.existsSync(result[0].imagePaths[0]));assert(!fs.existsSync(a.job));assert(!fs.existsSync(store.journal));
});
