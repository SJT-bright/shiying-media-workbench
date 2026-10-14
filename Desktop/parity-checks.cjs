const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const updates=require('./updates.cjs'),core=require('./core.cjs');
async function parityChecks(ctx,fixtures) {
 const {win,library}=ctx,{record,output,picture,report,c}=fixtures;
 const js=s=>win.webContents.executeJavaScript(s),sleep=ms=>new Promise(r=>setTimeout(r,ms));
 const rpc=(name,value)=>js(`window.shiying.call(${JSON.stringify(name)},${JSON.stringify(value)})`);
 async function wait(condition,label){const end=Date.now()+12000;while(Date.now()<end){if(await condition())return;await sleep(20);}throw Error('Timeout: '+label);}
 async function shot(name){await sleep(100);fs.writeFileSync(path.join(path.dirname(report),'windows-parity-'+name+'.png'),(await win.webContents.capturePage()).toPNG());}
 const playable=library.state.records.find(r=>r.path===output&&r.mediaKind==='video');if(!playable)throw Error('Playable fixture missing');
 await js(`navigate('records').then(()=>document.querySelector('[data-record="${playable.id}"] .record-cover').click())`);
 await wait(()=>js('!!document.querySelector(".play-progress")'),'persistent playback controls');
 await wait(()=>js('Number.isFinite(document.querySelector(".inline-player")?.duration)&&document.querySelector(".inline-player").duration>1'),'video metadata ready');
 record('playback progress pause and speed remain visible without system floating controls',await js('!!document.querySelector(".play-progress") && !!document.querySelector(".play-pause") && document.querySelector(".play-rate").options.length===7'));
 await js('document.querySelector(".play-rate").value="2";document.querySelector(".play-rate").dispatchEvent(new Event("change"));document.querySelector(".play-pause").click()');
 record('native video accepts 2x speed and pause',await js('document.querySelector(".inline-player").playbackRate===2 && document.querySelector(".inline-player").paused'));
 await js('document.querySelector(".play-progress").value="0.5";document.querySelector(".play-progress").dispatchEvent(new Event("input"))');
 await sleep(150);
 record('paused scrub seeks the real local video',await js('Math.abs(document.querySelector(".inline-player").currentTime/document.querySelector(".inline-player").duration-0.5)<0.12'));
 await shot('playback');await js("navigate('single')");
 const holds=new Set(); let scanID='fixture_creator_123',scanPosts=[];
 const makeLink=n=>'https://www.douyin.com/video/'+(7700000000000000000n+BigInt(n));
 ctx.setFlowFixture(async(args,emit,cancelled)=> {
  const kind=args[0],link=args[args.indexOf('--link')+1]||'',folder=args[args.indexOf('--folder')+1];
  if(kind==='scan') {
   const platform=args[args.indexOf('--platform')+1],home=platform==='bilibili'?'https://space.bilibili.com/'+scanID:'https://www.douyin.com/user/'+scanID;
   emit({event:'creator',id:scanID,nickname:'离线订阅作者',homepage:home});
   for(const post of scanPosts)emit({event:'post',post});emit({event:'scan_complete',complete:true});return {terminal:{event:'scan_complete',complete:true}};
  }
  const id=new URL(link).pathname.split('/').pop(),meta={event:'metadata',id,title:'离线作品 '+id,author:'测试作者',duration:2,statistics:{likeCount:1234,commentCount:3,shareCount:4}};
  emit(meta);emit({event:'progress',stage:'download',progress:.25,detail:'正在下载视频'});
  while(holds.has(id)&&!cancelled())await sleep(10);if(cancelled())throw Error('任务已取消');
  if(kind==='info')return {metadata:meta,terminal:null};
  fs.mkdirSync(folder,{recursive:true});const file=path.join(folder,id+'-'+crypto.randomUUID()+'.mp4');fs.copyFileSync(output,file);
  const terminal={event:'complete',path:file,width:854,height:480,bytes:fs.statSync(file).size,duration:2,video:meta};emit(terminal);return {metadata:meta,terminal};
 });
 const shares=[makeLink(1),makeLink(2)];await js(`document.querySelector('#singleLink').value=${JSON.stringify(shares.join('\n')+'\n'+shares[0])}`);
 await rpc('task',{kind:'info',link:shares.join('\n')+'\n'+shares[0],selection:{video:true,cover:false}});
 await wait(()=>js('document.querySelectorAll(".multi-link-card").length===2'),'multi cards');
 record('multi-link parse retains two distinct ordered glass cards', (await ctx.state()).multiItems.map(x=>x.link).join('|')===shares.join('|'));
 await shot('multi');const before=library.state.records.length;
 await rpc('multi-action',{id:(await ctx.state()).multiItems[0].id,action:'download'});
 record('one card downloads independently and leaves next ready',(await ctx.state()).multiItems[0].status==='completed'&&(await ctx.state()).multiItems[1].status==='ready'&&library.state.records.length===before+1);
 await rpc('multi-action',{action:'all'});record('download all only saves remaining ready items',library.state.records.length===before+2);
 await rpc('photo-cancel');
 ctx.setCoverFixture(picture);
 await rpc('task',{kind:'info',link:shares.join('\n'),selection:{video:false,cover:true}});
 const covers=(await ctx.state()).multiItems;const paths=covers.flatMap(x=>x.images);
 record('multi covers wait for independent confirmations',covers.length===2&&covers.every(x=>x.hasDraft)&&paths.every(p=>fs.existsSync(p)));
 await rpc('multi-action',{id:covers[0].id,action:'confirm'});await rpc('multi-action',{id:covers[1].id,action:'cancel'});
 record('confirming one cover and cancelling another cleans only their drafts',library.state.records.length===before+3&&paths.every(p=>!fs.existsSync(p)));
 await rpc('photo-cancel');
 ctx.setCoverFixture(null);
 await rpc('task',{kind:'download',link:'https://weixin.qq.com/sph/NATIVE_STATS',selection:{video:true,cover:false}});
 const wechat=library.state.records[0];record('video-channel statistics persist with a successful save',library.state.statistics[core.statisticKey(wechat).id]?.likes===1234);
 // Reproduce 22 old queue entries followed by 15 current tasks, with a held fifth.
 const targets=Array.from({length:15},(_,i)=>({id:crypto.randomUUID(),link:makeLink(i+22),videoID:new URL(makeLink(i+22)).pathname.split('/').pop(),collectionID:c.id,quality:'highest',wantsAudio:false,status:'pending'}));
 library.update(d=>{d.queue=[...Array.from({length:22},(_,i)=>({id:crypto.randomUUID(),title:'历史 '+i,status:'completed',collectionID:c.id})),...targets];});
 const fifth=targets[4].videoID;holds.add(fifth);await js("navigate('queue').then(()=>document.querySelector('#startQueue').click())");
 await wait(async()=>{const s=await ctx.state();return s.queueRun?.done===4&&s.progress?.detail.includes('正在下载视频');},'fifth current job');
 await wait(()=>js('document.querySelector("#footerTitle").textContent.includes("5/15")'),'native fifth count');
 record('native current counter is 5/15 with 22 historical tasks',(await ctx.state()).progress.detail==='本轮 5/15 · 正在下载视频');
 record('native footer separately labels the complete 37-task library',await js('document.querySelector("#footerStats").textContent.includes("全部任务")&&document.querySelector("#footerStats").textContent.includes("共 37")'));
 await shot('queue');await js('document.querySelector("#pauseQueue").click()');holds.delete(fifth);
 await wait(async()=>{const s=await ctx.state();return !s.busy&&s.queuePaused;},'pause after fifth');
 record('pause waits for the active item and retains ten pending tasks',library.state.queue.filter(x=>x.status==='pending').length===10);
 const sixth=targets[5].videoID;holds.add(sixth);await js('document.querySelector("#resumeQueue").click()');
 await wait(async()=>{const s=await ctx.state();return s.progress?.detail==='本轮 1/10 · 正在下载视频';},'resumed remaining scope');
 record('resume restarts its remaining task count at 1/10', (await ctx.state()).queueRun.total===10);holds.delete(sixth);
 await wait(async()=>!(await ctx.state()).busy,'queue completion');record('the complete queue preserves all 22 old tasks and completes 15 new tasks',library.state.queue.length===37&&library.state.queue.every(x=>x.status==='completed'));
 // A subscription updates only its new tasks, leaving an unrelated pending job.
 scanPosts=[40,41].map(n=>({id:new URL(makeLink(n)).pathname.split('/').pop(),link:makeLink(n),title:'订阅作品 '+n,isVideo:true}));
 await rpc('task',{kind:'scan',platform:'douyin',link:'https://www.douyin.com/user/'+scanID});
 await rpc('subscribe',{platform:'douyin',collectionID:c.id,audio:false});
 const sub=(await ctx.state()).subscriptions[0];const other={...targets[0],id:crypto.randomUUID(),link:makeLink(99),status:'pending'};library.update(d=>d.queue.push(other));
 await js("navigate('creator');document.querySelector('#creatorSubscriptions').click()");await shot('subscriptions');
 const update=await rpc('subscription-update',{id:sub.id});record('subscription automatically downloads exactly its two new works',update.added===2&&library.state.queue.filter(x=>scanPosts.some(p=>p.id===x.videoID)).every(x=>x.status==='completed'));
 record('subscription leaves an unrelated pending task untouched',library.state.queue.find(x=>x.id===other.id).status==='pending');
 record('repeating a subscription update adds zero duplicate jobs',(await rpc('subscription-update',{id:sub.id})).added===0);
 const saved=library.state.records.find(x=>x.videoID===scanPosts[0].id);fs.unlinkSync(saved.path);
 record('missing saved video is recovered without changing its historical record',(await rpc('subscription-update',{id:sub.id})).added===1&&library.state.records.some(x=>x.id===saved.id));
 record('subscriptions survive a cold repository read',new updates.Subscriptions(ctx.dataRoot).rows[0].id===sub.id);
 await rpc('unsubscribe',{id:sub.id});record('cancelling a subscription preserves downloaded media and records',!(await ctx.state()).subscriptions.length&&library.state.records.some(x=>x.videoID===scanPosts[1].id));
 await js('document.querySelector("#subscriptionsClose").click()');
 scanID='12345';scanPosts=[{id:'BV1234567890',link:'https://www.bilibili.com/video/BV1234567890',title:'B站订阅作品',isVideo:true}];
 await rpc('task',{kind:'scan',platform:'bilibili',link:'https://space.bilibili.com/12345'});await rpc('subscribe',{platform:'bilibili',collectionID:c.id,audio:false});
 record('Bilibili uses stable numeric creator identity',(await ctx.state()).subscriptions[0].creatorID==='12345');
 record('Bilibili incremental download completes with independent platform identity',(await rpc('subscription-update',{id:(await ctx.state()).subscriptions[0].id})).added===1);
 await rpc('settings',{folder:library.collection(c.id).path});
 record('shared save directory is connected to an existing collection',library.state.collections.some(x=>x.path===library.state.settings.folder));
 await rpc('settings',{revealOnComplete:false,theme:'light'});await js('refresh()');
 record('day and night controls and completion location preference are present',await js('!!document.querySelector("#themeLight")&&!!document.querySelector("#themeDark")&&!document.querySelector("#revealComplete").checked&&document.body.classList.contains("light")'));
 await rpc('settings',{theme:'dark'});await js('refresh()');
 record('header and sidebar expose matching counts',await js('document.querySelectorAll(".nav-badge").length===7&&!!document.querySelector("#headerMatches")'));
 ctx.setFlowFixture(null);await js("navigate('single')");
}
module.exports={parityChecks};
