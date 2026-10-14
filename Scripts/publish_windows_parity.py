"""Publish a Windows release only after exact-source native package validation."""
import hashlib,json,os,re,subprocess,sys,zipfile
from pathlib import Path
SOURCE=os.environ['SHIYING_SOURCE'];RUN=os.environ['SHIYING_RUN']
assert re.fullmatch(r'[a-f0-9]{40}',SOURCE) and RUN.isdigit()
REPO='SJT-bright/shiying-media-workbench';VERSION='1.8.6';TAG='v'+VERSION
PIN='4f0bed8483c35a980315d9c7b3a1d4a1119ad2b2'
root=Path('snapshot').resolve();assets=Path('assets').resolve()
def command(args,**kwargs):return subprocess.check_output(args,**kwargs).decode().strip()
def api(endpoint):return json.loads(command(['gh','api',endpoint]))
def sha(data):return hashlib.sha256(data).hexdigest()
assert command(['git','rev-parse','HEAD'],cwd=root)==SOURCE
assert command(['git','rev-parse','HEAD'],cwd=root/'Backend/upstream')==PIN
run=api(f'repos/{REPO}/actions/runs/{RUN}')
assert run['conclusion']=='success' and run['head_sha']==SOURCE
counts={}
for name in ['windows-runtime.json','windows-portable-runtime.json','windows-installed-runtime.json']:
 r=json.loads((assets/name).read_text())
 assert r['passed'] and r['packaged'] and r['platform']=='win32' and r['version']==VERSION
 assert len(r['checks'])>=71 and all(c['passed'] for c in r['checks'])
 assert r['provenance']['sourceCommit']==SOURCE and r['provenance']['upstreamCommit']==PIN
 for name_,value in r['provenance']['workerSources'].items():
  raw=(root/'Backend'/name_).read_bytes();assert value in {sha(raw),sha(raw.replace(b'\n',b'\r\n'))}
 counts[name]=len(r['checks'])
for line in (assets/'SHA256SUMS.txt').read_text(encoding='utf-8-sig').splitlines():
 digest,name=line.split(None,1);assert sha((assets/name.strip()).read_bytes())==digest.lower()
with zipfile.ZipFile(assets/f'Shiying-{VERSION}-Windows-x64.zip') as z:
 assert z.testzip() is None
 for name in ['ffmpeg.exe','ffprobe.exe','config.h','config.mak','source-components.json']:
  member=next(n for n in z.namelist() if n.endswith('resources/Tools/'+name))
  assert sha(z.read(member))==sha((Path('media-tools')/name).read_bytes())
archive=assets/f'Shiying-{VERSION}-source.zip';prefix=f'Shiying-{VERSION}/'
subprocess.run(['git','archive','--format=zip','--prefix='+prefix,'-o',str(archive),SOURCE],cwd=root,check=True)
files=command(['git','ls-tree','-r','--name-only',PIN],cwd=root/'Backend/upstream').splitlines()
with zipfile.ZipFile(archive,'a',compression=zipfile.ZIP_DEFLATED) as z:
 for name in files:z.writestr(prefix+'Backend/upstream/'+name,subprocess.check_output(['git','show',PIN+':'+name],cwd=root/'Backend/upstream'))
 for name in ['config.h','config.mak','source-components.json']:z.writestr(prefix+'BuildConfigs/Windows/'+name,(Path('media-tools')/name).read_bytes())
 z.writestr(prefix+'SOURCE-RELEASE.json',json.dumps({'sourceCommit':SOURCE,'upstreamCommit':PIN,'version':VERSION,'macSourceBaseline':'1.8.6/build42','publisherToolingCommit':command(['git','rev-parse','HEAD'])},indent=2)+'\n')
subprocess.run([sys.executable,str(Path(__file__).with_name('audit_release.py')),str(assets)],check=True)
manifest={p.name:sha(p.read_bytes()) for p in sorted(assets.iterdir()) if p.is_file() and p.name!='SHA256SUMS.txt'}
(assets/'SHA256SUMS.txt').write_text(''.join(f'{digest}  {name}\n' for name,digest in manifest.items()))
notes=Path('release-notes.md');notes.write_text(f'''拾影 Windows {VERSION}，同步 Mac 1.8.6/build42 的界面布局与操作流程。

新增多链接独立玻璃卡片、逐条/全部下载、图片与封面逐条确认取消；抖音与B站博主订阅及手动增量更新、跨单条/批量资料查重、缺失文件补下载。视频号统计在成功保存时同步保存。卡片内常驻进度、暂停继续、拖动与0.5×到3×倍速。批量计数统一为本轮序号/本轮总数，全库累计独立标注，修复28/15等历史偏移问题；暂停继续与订阅限定下载范围一致。

- Windows10/11 x64安装版：Shiying-{VERSION}-Windows-x64-Setup.exe。
- Windows免安装版：Shiying-{VERSION}-Windows-x64.zip，解压后运行拾影.exe。
- 双端完整源码：Shiying-{VERSION}-source.zip，含Mac 1.8.6源码、Windows主线、固定解析模块、媒体对应源码及确切Windows配置。

Windows原生EXE、便携ZIP和Setup实际安装后三份报告各{counts['windows-runtime.json']}项通过，包含真实本地音视频解码、拖动/倍速、5/15进度、订阅两平台增量、重复更新和封面事务。平台采集用离线合成协议验证；真实账号、平台当前访问范围及不同电脑DPI/显卡仍以对应实机为准。系统字体、窗口边框与玻璃效果由Windows实现。Windows包无商业签名证书。

安装包自带worker和FFmpeg，无需另外安装Python、Node或FFmpeg；卸载保留用户资料，取消订阅保留媒体。视频号暂不提供博主主页订阅，小红书只更新可访问的部分主页；公众号不读取互动数。

源码/tag：{SOURCE}；固定解析模块：{PIN}；原生构建与验收：https://github.com/{REPO}/actions/runs/{RUN} 。全部发行资产完整重下载并校验SHA256。此发行提供Windows安装包和双端源码，本机Mac正式应用没有被该Windows任务替换或重启。
''',encoding='utf-8')
existing=subprocess.run(['gh','release','view',TAG,'--repo',REPO,'--json','isDraft,targetCommitish'],capture_output=True,text=True)
if existing.returncode==0:
 r=json.loads(existing.stdout);assert r['isDraft'] and r['targetCommitish']==SOURCE
 subprocess.run(['gh','release','upload',TAG,'--repo',REPO,'--clobber',*[str(p) for p in assets.iterdir() if p.is_file()]],check=True)
 subprocess.run(['gh','release','edit',TAG,'--repo',REPO,'--notes-file',str(notes)],check=True)
else:subprocess.run(['gh','release','create',TAG,'--repo',REPO,'--draft','--target',SOURCE,'--title',f'拾影 {VERSION} · Windows同步Mac最新功能','--notes-file',str(notes),*[str(p) for p in assets.iterdir() if p.is_file()]],check=True)
download=Path('downloaded-release');download.mkdir(exist_ok=True)
subprocess.run(['gh','release','download',TAG,'--repo',REPO,'--dir',str(download),'--clobber'],check=True)
for name,digest in manifest.items():assert sha((download/name).read_bytes())==digest
assert (download/'SHA256SUMS.txt').read_bytes()==(assets/'SHA256SUMS.txt').read_bytes()
subprocess.run(['gh','release','edit',TAG,'--repo',REPO,'--draft=false','--latest'],check=True)
assert api(f'repos/{REPO}/git/ref/tags/{TAG}')['object']['sha']==SOURCE
receipt={'published':True,'sourceCommit':SOURCE,'release':f'https://github.com/{REPO}/releases/tag/{TAG}','windowsRuntimeChecks':counts,'verifiedAssets':manifest}
Path('publication-verification.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
