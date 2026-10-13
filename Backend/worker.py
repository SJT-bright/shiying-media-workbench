"""JSON-lines worker for 拾影; uses pinned upstream signer/parser, no server stack."""
from __future__ import annotations
import argparse, asyncio, json, os, re, signal, subprocess, sys, tempfile, time, shutil, logging, threading, _thread
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit
# Adapters must share this entry point's active_child and cancellation state.
if __name__=='__main__': sys.modules['worker']=sys.modules[__name__]
sys.path.insert(0, str(Path(__file__).parent / 'upstream' / 'src'))
import httpx, structlog
from dtk.core.types import Platform
from dtk.signing.base import RequestSpec, StaticFingerprint, SigningSession
from dtk.signing.native.signer import NativeSigner
from dtk.platforms.douyin.params import content_detail_params, DEFAULT_PROFILE
from dtk.platforms.douyin.parser import parse_content
from dtk.core.errors import UpstreamChanged, UpstreamRiskControl
structlog.configure(wrapper_class=structlog.make_filtering_bound_logger(logging.CRITICAL))
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
active_child=None
class Cancelled(Exception): pass

def emit(event, **data): print(json.dumps({'event':event, **data},ensure_ascii=False),flush=True)
def cancel(signum,frame):
 global active_child
 if active_child and active_child.poll() is None:
  active_child.terminate()
  try: active_child.wait(timeout=3)
  except subprocess.TimeoutExpired: active_child.kill(); active_child.wait()
 raise Cancelled()

def input_link(text):
 urls=re.findall(r'https?://[^\s<>"\u3000]+',text.replace('\\:',':'))
 for u in urls:
  u=u.rstrip('，。！!；;）)')
  host=(urlsplit(u).hostname or '').lower()
  if host in {'v.douyin.com','www.douyin.com','douyin.com','www.iesdouyin.com','iesdouyin.com'}:
   return u
 if re.fullmatch(r'\d{19}',text.strip()): return 'https://www.douyin.com/video/'+text.strip()
 raise ValueError('请粘贴抖音视频链接或完整分享文案。')

def id_from_url(url):
 m=re.search(r'/(?:video|note)/(\d{19})',url)
 return m.group(1) if m else None

def choose_stream(content,quality):
 streams=[s for s in [content.media.video,*content.media.streams] if s and not s.watermark and s.width and s.height]
 if not streams: raise ValueError('该作品没有可下载的视频源，可能是图文作品或访问受限。')
 if quality=='highest': return max(streams,key=lambda s:(s.width*s.height,s.bitrate or 0))
 target=int(quality); sufficient=[s for s in streams if min(s.width,s.height)>=target]
 if sufficient:
  size=min(min(s.width,s.height) for s in sufficient)
  return max([s for s in sufficient if min(s.width,s.height)==size],key=lambda s:s.bitrate or 0)
 return max(streams,key=lambda s:(s.width*s.height,s.bitrate or 0))

def utf8_limit(text,limit):
 return text.encode("utf-8")[:limit].decode("utf-8",errors="ignore")

def dimensions(w,h,target):
 if min(w,h)<=target: return w,h
 ratio=target/min(w,h)
 return max(2,round(w*ratio/2)*2),max(2,round(h*ratio/2)*2)

async def fetch(text, session=None, cover_only=False):
 link=input_link(text)
 async with httpx.AsyncClient(headers={'User-Agent':UA,'Referer':'https://www.douyin.com/'},follow_redirects=True,timeout=25) as client:
  # HEAD expands short URLs and supplies the public visitor UIFID cookie; no account cookie.
  r=await client.head(link)
  video_id=id_from_url(str(r.url)) or id_from_url(link)
  if not video_id: raise ValueError('链接没有指向单个视频，请重新复制视频的分享链接。')
  # Public short-link expansion stays anonymous. Only the detail request below
  # receives this app's explicitly validated, domain-scoped Douyin session.
  if session is not None:
   if not isinstance(session,httpx.Cookies): raise ValueError('登录状态无法读取，请重新打开登录窗口。')
   for cookie in session.jar:
    host=cookie.domain.lstrip('.').lower()
    if (host!='douyin.com' and not host.endswith('.douyin.com')) or not cookie.secure:
     raise ValueError('登录状态无法读取，请重新打开登录窗口。')
    client.cookies.jar.set_cookie(cookie)
  spec=RequestSpec.get('https://www.douyin.com/aweme/v1/web/aweme/detail/',content_detail_params(aweme_id=video_id,profile=DEFAULT_PROFILE))
  signed=await NativeSigner(Platform.DOUYIN).sign(spec,StaticFingerprint(UA,'Win32',1920,1080),SigningSession({c.name:c.value for c in client.cookies.jar}))
  if session is not None:
   r=await client.get(signed.signed_url(spec.url),headers=dict(signed.headers),follow_redirects=False)
  else: r=await client.get(signed.signed_url(spec.url),headers=dict(signed.headers))
  if r.status_code!=200: raise ValueError(f'读取视频详情失败：抖音接口返回 HTTP {r.status_code}，请在内置网页检查该作品是否可访问后重试。')
  if not r.content: raise ValueError('读取视频详情失败：接口返回 0 字节空响应；平台没有提供具体原因，请稍后重试。')
  try: payload=r.json()
  except ValueError: raise ValueError(f'读取视频详情失败：接口返回非 JSON 内容（{len(r.content)} 字节），可能需要在内置网页完成验证。') from None
  try:
   if cover_only:
    from cover_worker import parse_douyin_cover
    content=parse_douyin_cover(payload,fetched_at=datetime.now(timezone.utc))
   else: content=parse_content(payload,fetched_at=datetime.now(timezone.utc))
  except UpstreamRiskControl: raise ValueError('读取视频详情失败：抖音接口明确返回访问限制，请在内置网页检查登录或验证提示。') from None
  except UpstreamChanged: raise ValueError('读取视频详情失败：响应缺少解析器需要的作品字段（upstream_schema），需要检查接口兼容。') from None
  if content.content_id!=video_id: raise ValueError('视频 ID 不一致，已停止下载。')
  return content,link

def summary(content):
 import photo_worker
 if photo_worker.is_album(content): return photo_worker.metadata(content)
 best=choose_stream(content,'highest')
 cover=content.media.covers[0].urls[0] if content.media.covers and content.media.covers[0].urls else None
 return {'id':content.content_id,'title':content.title[:180],'description':content.description or content.title,'author':content.author.nickname,'duration':(content.duration_ms or 0)/1000,'width':best.width,'height':best.height,'size':best.size_bytes or 0,'cover':cover}

def tool(name):
 base=Path(sys.executable).parent.parent/'Tools' if getattr(sys,'frozen',False) else Path(os.environ.get('POCKET_TOOLS','/opt/homebrew/bin'))
 p=base/(name+'.exe' if sys.platform=='win32' else name)
 if not p.is_file(): raise ValueError(f'应用媒体组件 {name} 缺失，请重新安装拾影。')
 return str(p)

def file_component(text, limit):
 value=re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', text).strip(' .')
 if re.fullmatch(r'(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?',value,re.I):value='_'+value
 return utf8_limit(value,limit)

def stage_prefix(kind):
 token=os.environ.get('SHIYING_JOB_TOKEN','')
 return f'.shiying-{token}-{kind}-' if re.fullmatch(r'[a-f0-9]{32}',token) else f'.shiying-{kind}-'

def watch_cancel(cancel_file, stopped):
 # The Windows process receives a private file signal; no console or global kill.
 while not stopped.wait(.15):
  if Path(cancel_file).is_file():
   child=active_child
   if child is not None and child.poll() is None:
    try:child.terminate()
    except OSError:pass
   _thread.interrupt_main(signal.SIGINT)
   return

def probe(path):
 r=subprocess.run([tool('ffprobe'),'-v','error','-show_entries','format=duration,size:stream=codec_type,width,height','-of','json',str(path)],capture_output=True,text=True,timeout=30)
 if r.returncode: raise ValueError(f'校验视频失败：ffprobe 退出码 {r.returncode}，下载文件不是可读取的视频；未发布到目标文件夹。')
 d=json.loads(r.stdout); v=next((s for s in d['streams'] if s['codec_type']=='video'),None)
 if not v: raise ValueError('下载结果缺少视频画面。')
 return int(v['width']),int(v['height']),float(d['format']['duration'])

def transcode(source,dest,target):
 global active_child
 w,h,duration=probe(source); width,height=dimensions(w,h,target)
 if (w,h)==(width,height): shutil.copyfile(source,dest); return
 args=[tool('ffmpeg'),'-hide_banner','-loglevel','error','-nostdin','-i',str(source),'-map','0:v:0','-map','0:a:0?','-vf',f'scale={width}:{height}:flags=lanczos,setsar=1','-c:v','libx264','-preset','veryfast','-crf','20','-pix_fmt','yuv420p','-c:a','aac','-b:a','160k','-movflags','+faststart','-progress','pipe:1','-nostats',str(dest)]
 with tempfile.TemporaryFile() as errors:
  active_child=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=errors,text=True)
  for line in active_child.stdout:
   if line.startswith('out_time_us='):
    try: emit('progress',stage='export',progress=min(.99,int(line.split('=')[1])/1e6/max(duration,1)),detail=f'正在导出 {target}P')
    except ValueError: pass
  code=active_child.wait(); active_child.stdout.close(); active_child=None
  if code: raise ValueError(f'画质转换失败：ffmpeg 退出码 {code}。请重试或选择最高画质。')
 ow,oh,_=probe(dest)
 if (ow,oh)!=(width,height): raise ValueError('导出分辨率验证失败。')

async def download(text,quality,folder,video_only=False):
 emit('progress',stage='parse',progress=0,detail='正在获取作品信息')
 content,link=await fetch(text)
 import photo_worker
 if photo_worker.is_album(content):
  if video_only: raise ValueError('作品已识别为图文，请重新解析后复制或确认保存。')
  return await photo_worker.download_album(content,folder)
 info=summary(content); emit('metadata',**info)
 stream=choose_stream(content,quality)
 out=Path(folder).expanduser()
 if not out.is_dir(): raise ValueError('保存文件夹不存在，请重新选择保存位置。')
 title=file_component(content.title,120) or content.content_id
 author=file_component(content.author.nickname,48)
 quality_label='最高画质' if quality=='highest' else quality+'P'
 with tempfile.TemporaryDirectory(prefix=stage_prefix('download'),dir=out) as staging:
  staging=Path(staging); source=staging/'source.mp4'; final=staging/'output.mp4'
  emit('progress',stage='download',progress=0,detail='正在下载视频')
  async with httpx.AsyncClient(headers={'User-Agent':UA,'Referer':'https://www.douyin.com/'},follow_redirects=True,timeout=40) as client:
   failures=[]
   for url in dict.fromkeys([stream.url,*stream.urls]):
    try:
     async with client.stream('GET',url) as r:
      r.raise_for_status(); total=int(r.headers.get('content-length') or stream.size_bytes or 0); got=0; start=time.monotonic(); last=0
      if not any(x in r.headers.get('content-type','') for x in ('video','octet-stream')): raise ValueError('服务器返回的内容类型不是视频')
      with source.open('wb') as f:
       async for chunk in r.aiter_bytes(256*1024):
        f.write(chunk); got+=len(chunk)
        if time.monotonic()-last>.15:
         last=time.monotonic(); emit('progress',stage='download',progress=got/total if total else 0,detail='正在下载视频',received=got,total=total,speed=got/max(time.monotonic()-start,.1))
     if total and got!=total: raise ValueError(f'下载字节不完整：预计 {total}，收到 {got}')
     if stream.size_bytes and got!=stream.size_bytes: raise ValueError(f'文件大小与作品信息不符：预计 {stream.size_bytes}，收到 {got}')
     break
    except (httpx.HTTPError,ValueError,OSError) as exc:
     if isinstance(exc,OSError) and not isinstance(exc,httpx.HTTPError): raise
     failure=(f'HTTP {exc.response.status_code}' if isinstance(exc,httpx.HTTPStatusError) else
              '连接或读取超时' if isinstance(exc,httpx.TimeoutException) else
              f'网络传输错误（{type(exc).__name__}）' if isinstance(exc,httpx.HTTPError) else str(exc))
     failures.append(f'视频源 {len(failures)+1}：{failure}')
     source.unlink(missing_ok=True)
   else: raise ValueError('视频下载失败。'+'；'.join(failures)+'。请稍后重试。')
  emit('progress',stage='export',progress=0,detail='正在整理视频' if quality=='highest' else f'正在导出 {quality}P')
  if quality=='highest': source.rename(final)
  else: transcode(source,final,int(quality))
  emit('progress',stage='verify',progress=0,detail='正在检查视频文件')
  w,h,duration=probe(final)
  if content.duration_ms and abs(duration-content.duration_ms/1000)>max(2,content.duration_ms/1000*.01): raise ValueError('视频时长不完整，请重新下载。')
  # Atomic publish without replacing existing user files, even under a racing second instance.
  base=f'{author}_{title}_{quality_label}_{content.content_id}'
  for n in range(10000):
   dest=out/(base+(f'_{n}' if n else '')+'.mp4')
   try: os.link(final,dest); break
   except FileExistsError: continue
  else: raise ValueError('同名文件过多，请选择其他保存位置。')
  emit('complete',path=str(dest),width=w,height=h,duration=duration,bytes=dest.stat().st_size,quality=quality,**{'video':info})

def main():
 if hasattr(sys.stdout,'reconfigure'): sys.stdout.reconfigure(encoding='utf-8')
 stopped=threading.Event()
 signal.signal(signal.SIGTERM,cancel); signal.signal(signal.SIGINT,cancel)
 p=argparse.ArgumentParser(allow_abbrev=False); p.add_argument('command',choices=['info','download','convert','scan','metrics','articles','cover']); p.add_argument('--article-action',choices=['preview','download'],default='download'); p.add_argument('--link',default=''); p.add_argument('--quality',choices=['480','720','highest'],default='highest'); p.add_argument('--folder',default=''); p.add_argument('--preview-images',action='store_true'); p.add_argument('--preview-cover',action='store_true'); p.add_argument('--video-only',action='store_true'); p.add_argument('--input'); p.add_argument('--output'); p.add_argument('--resume-cursor',default=''); p.add_argument('--page-limit',type=int,default=None); p.add_argument('--seen-ids-file',default=''); p.add_argument('--prior-partial',action='store_true'); p.add_argument('--session-stdin',action='store_true'); p.add_argument('--platform',choices=['douyin','bilibili','xiaohongshu','wechat']); p.add_argument('--cancel-file',default=''); a=p.parse_args()
 try:
  if a.cancel_file:
   if not re.fullmatch(r'shiying-cancel-[a-f0-9]{32}\.signal',Path(a.cancel_file).name): raise ValueError('取消信号文件无效。')
   threading.Thread(target=watch_cancel,args=(a.cancel_file,stopped),daemon=True).start()
  if a.preview_cover and (a.command!='info' or a.preview_images):
   raise ValueError('封面预览需使用独立的 info --preview-cover 任务。')
  if a.command=='cover':
   import cover_worker
   if a.session_stdin: raise ValueError('已采集封面的下载任务不接受登录状态。')
   asyncio.run(cover_worker.run_cover(a.input,a.folder)); return 0
  if a.preview_cover:
   import cover_worker, platform_worker
   platform,_=platform_worker.input_url(a.link,a.platform)
   if a.session_stdin:
    session=cover_worker.read_douyin_session(sys.stdin.buffer) if platform=='douyin' else platform_worker.read_session(sys.stdin.buffer,platform)
   else: session=None
   asyncio.run(cover_worker.preview_cover(a.link,a.folder,platform,session)); return 0
  if a.command=='articles':
   import article_worker
   links,snapshots=article_worker.read_request(sys.stdin.buffer)
   return asyncio.run(article_worker.run_articles(links,snapshots,a.folder,a.article_action))
  if a.command=='metrics':
   import metrics_worker
   works,sessions=metrics_worker.read_multi_request(sys.stdin.buffer)
   return asyncio.run(metrics_worker.run_multi_metrics(works,sessions))
  # Existing Douyin commands and signer/parser remain untouched. Credentials for
  # the new platforms are bounded stdin data, never argv or other-browser reads.
  if a.command!='convert':
   import platform_worker
   platform,_=platform_worker.input_url(a.link,a.platform)
   if platform!='douyin':
    session=platform_worker.read_session(sys.stdin.buffer,platform) if a.session_stdin else None
    if a.command=='info':
     content,_=asyncio.run(platform_worker.fetch_info(a.link,platform,session)); emit('metadata',**platform_worker.metadata(content)); return 0
    if a.command=='download':
     asyncio.run(platform_worker.download(a.link,platform,a.quality,a.folder,session)); return 0
    import creator_worker
    seen_path=(a.seen_ids_file or '').strip()
    try:
     seen=platform_worker.load_seen_ids_file(seen_path) if seen_path else set()
     return asyncio.run(platform_worker.run_scan(a.link,platform,session=session,page_limit=500 if a.page_limit is None else a.page_limit,resume_cursor=(a.resume_cursor or '').strip() or None,seen_ids=seen,prior_partial=a.prior_partial))
    finally: creator_worker.discard_seen_file(seen_path)
  if a.command=='info':
   c,_=asyncio.run(fetch(a.link))
   import photo_worker
   if a.preview_images and photo_worker.is_album(c): asyncio.run(photo_worker.download_album(c,a.folder))
   else: emit('metadata',**summary(c))
  elif a.command=='download': asyncio.run(download(a.link,a.quality,a.folder,video_only=True) if a.video_only else download(a.link,a.quality,a.folder))
  elif a.command=='scan':
   import creator_worker
   limit=500 if a.page_limit is None else a.page_limit
   cursor=(a.resume_cursor or '').strip() or None
   seen_path=(a.seen_ids_file or '').strip()
   try:
    if isinstance(limit,bool) or not isinstance(limit,int) or limit<1 or limit>500:
     emit('error',message='单批页数必须在 1 到 500 之间。'); return 1
    try:
     seen,coauthored=creator_worker.load_seen_state(seen_path) if seen_path else (set(),set())
    except ValueError as exc:
     emit('error',message=str(exc)); return 1
    session=creator_worker.read_session(sys.stdin.buffer) if a.session_stdin else None
    return asyncio.run(creator_worker.run_scan(a.link,resume_cursor=cursor,page_limit=limit,seen_ids=seen,seen_coauthored_ids=coauthored,prior_partial=a.prior_partial is True,session_cookies=session))
   finally:
    creator_worker.discard_seen_file(seen_path)
  else: transcode(Path(a.input),Path(a.output),int(a.quality)); emit('converted',output=a.output)
 except Cancelled: emit('cancelled'); return 130
 except Exception as e:
  operation={'scan':'采集作品','info':'读取作品信息','download':'下载视频','convert':'转换视频','cover':'下载封面'}.get(a.command,'处理作品')
  if isinstance(e,ValueError): message=str(e)
  elif isinstance(e,httpx.HTTPStatusError): message=f'{operation}失败：服务器返回 HTTP {e.response.status_code}。'
  elif isinstance(e,httpx.TimeoutException): message=f'{operation}失败：网络连接或读取超时，请检查网络后重试。'
  elif isinstance(e,httpx.HTTPError): message=f'{operation}失败：网络传输错误（{type(e).__name__}），请检查网络后重试。'
  elif isinstance(e,OSError):
   import errno
   detail={errno.ENOSPC:'磁盘空间不足',errno.EACCES:'没有文件读写权限',errno.EPERM:'系统拒绝文件操作',errno.EROFS:'目标卷只读',errno.ENOENT:'需要的文件或目录不存在'}.get(e.errno,f'系统文件错误 errno={e.errno}')
   message=f'{operation}失败：{detail}。请检查保存位置；已有文件保留。'
  elif isinstance(e,subprocess.TimeoutExpired): message=f'{operation}失败：媒体处理组件超过 {e.timeout} 秒未完成。'
  else: message=f'{operation}发生内部错误（{type(e).__name__}）。请记录此问题代码以便修复；已有文件保留。'
  extra={'reason':e.reason} if hasattr(e,'reason') else {}
  extra['diagnostic']={'code':getattr(e,'reason','worker_exception'),'stage':a.command,'errorType':type(e).__name__}
  emit('error',message=message,**extra); return 1
 finally:
  stopped.set()
  # Even URL/platform validation may fail before a scan adapter is entered.
  # Delete only the app-owned temporary handoff, using the existing safe guard.
  if a.command=='scan' and (a.seen_ids_file or '').strip():
   import creator_worker
   creator_worker.discard_seen_file(a.seen_ids_file.strip())
 return 0
if __name__=='__main__': sys.exit(main())
