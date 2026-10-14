const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {MediaStreams}=require('../media-streams.cjs');
test('owned preview handles close before removal while unrelated media stays open',async t=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'shiying-stream-')),owned=path.join(root,'owned'),other=path.join(root,'other');fs.mkdirSync(owned);fs.mkdirSync(other);
 const a=path.join(owned,'image.png'),b=path.join(other,'video.mp4');fs.writeFileSync(a,'preview');fs.writeFileSync(b,'saved');
 const alias=path.join(root,'alias');fs.symlinkSync(owned,alias,process.platform==='win32'?'junction':'dir');
 const streams=new MediaStreams(),preview=streams.open(path.join(alias,'image.png')),saved=streams.open(b);
 await Promise.all([preview,saved].map(s=>new Promise(resolve=>s.once('open',resolve))));
 await streams.closeOwned([owned]);assert(preview.closed);assert(!saved.closed);assert.throws(()=>streams.open(a),/预览已结束/);fs.rmSync(owned,{recursive:true});assert(fs.existsSync(b));
 await streams.closeOwned([other]);assert.equal(streams.active.size,0);fs.rmSync(root,{recursive:true});
});
