const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const u=require('../updates.cjs'),core=require('../core.cjs');
const video=n=>'https://www.douyin.com/video/'+(7500000000000000000n+BigInt(n));
function root(t){const p=fs.mkdtempSync(path.join(os.tmpdir(),'shiying-updates-'));t.after(()=>fs.rmSync(p,{recursive:true,force:true}));return p;}
test('multi shares retain order, deduplicate stable URLs and reject over-limit whole input',()=>{
 assert.deepEqual(u.links('分享 '+video(1)+'?foo=bar\n'+video(2)+'。\n'+video(1)+'?other=1'),[video(1)+'?foo=bar',video(2)]);
 assert.throws(()=>u.links(Array.from({length:201},(_,i)=>video(i)).join('\n')),/200/);
 assert.throws(()=>u.links('a'.repeat(5*1024*1024+1)),/MiB/);
 assert.throws(()=>u.links('https://example.com/video/123'),/没有支持/);
});
test('subscriptions persist stable per-platform identity and updated settings without duplication',t=>{
 const p=root(t),repo=new u.Subscriptions(p),data={platform:'douyin',creatorID:'fixture_creator_123',homepage:'https://www.douyin.com/user/fixture_creator_123',name:'同名作者',quality:'highest',collectionID:'folder',includeAudio:true};
 const first=repo.subscribe(data);repo.subscribe({...data,quality:'480'});assert.equal(repo.rows.length,1);assert.equal(repo.rows[0].id,first.id);
 repo.subscribe({...data,platform:'bilibili',creatorID:'12345',homepage:'https://space.bilibili.com/12345'});assert.equal(new u.Subscriptions(p).rows.length,2);
 assert.throws(()=>repo.subscribe({...data,creatorID:'wrong',homepage:data.homepage}),/身份/);
 assert.throws(()=>repo.subscribe({...data,platform:'wechat'}),/视频号/);
 assert.throws(()=>repo.subscribe({...data,quality:'unsupported'}),/字段/);
 assert.equal(new u.Subscriptions(p).rows[0].quality,'480');
});
test('bad, externally changed and locked subscription stores preserve original bytes',t=>{
 const p=root(t),file=path.join(p,'creator-subscriptions.json');fs.writeFileSync(file,'invalid');const repo=new u.Subscriptions(p);
 assert(repo.blocked);assert.throws(()=>repo.update(()=>{}),/无法读取/);assert.equal(fs.readFileSync(file,'utf8'),'invalid');fs.unlinkSync(file);
 const next=new u.Subscriptions(p);fs.writeFileSync(file,'external');assert.throws(()=>next.update(()=>{}),/外部修改/);assert.equal(fs.readFileSync(file,'utf8'),'external');assert(!fs.existsSync(file+'.lock'));
 fs.writeFileSync(file+'.lock','other');assert.throws(()=>next.update(()=>{}),/EEXIST/);assert.equal(fs.readFileSync(file+'.lock','utf8'),'other');
});
test('cross-library known works exclude missing files, failed jobs and cover-only records',t=>{
 const p=root(t),saved=path.join(p,'saved.mp4');fs.writeFileSync(saved,'saved');const l=new core.Library(p);
 l.state.records=[{link:video(1),videoID:video(1).split('/').pop(),path:saved},{link:video(2),path:saved,mediaKind:'video_cover'},{link:video(3),path:path.join(p,'missing')}];
 l.state.queue=[{link:video(4),status:'pending'},{link:video(5),status:'failed'}];
 const posts=[1,2,3,4,5].map(n=>({id:video(n).split('/').pop(),link:video(n),isVideo:true}));
 assert.deepEqual(u.missing(posts,'douyin',u.known(l)).map(x=>x.link),[video(2),video(3),video(5)]);
 assert.deepEqual(u.missing([{...posts[0],id:'wrong'}, {...posts[1],isVideo:false}], 'douyin',new Set()),[]);
});
test('subscription recovery creates a new pending task while leaving historical records intact',t=>{
 const p=root(t),l=new core.Library(p),c=l.create('媒体',null,'',p),post={id:video(7).split('/').pop(),link:video(7),isVideo:true};
 l.state.records=[{id:'old',collectionID:c.id,videoID:post.id,link:post.link,path:path.join(p,'missing.mp4')}];
 l.state.queue=[{id:'failed',collectionID:c.id,videoID:post.id,link:post.link,status:'failed'}];
 assert.equal(l.enqueuePosts([post],c.id,'https://www.douyin.com/user/fixture_creator_123','720',false,true),1);
 assert.equal(l.state.queue[0].status,'failed');assert.equal(l.state.queue[1].status,'pending');assert.equal(l.state.records[0].id,'old');
});
test('an interrupted subscription writer leaves a recoverable owned lock',t=>{
 const p=root(t),repo=new u.Subscriptions(p),lock=repo.file+'.lock';
 const child=require('node:child_process').spawnSync(process.execPath,['-e',"require('node:fs').writeFileSync(process.argv[1],JSON.stringify({kind:'shiying-subscription-lock',pid:process.pid,token:require('node:crypto').randomUUID()}));process.exit(23)",lock]);
 assert.equal(child.status,23);repo.update(()=>{});assert(!fs.existsSync(lock));assert.equal(new u.Subscriptions(p).blocked,null);
});
