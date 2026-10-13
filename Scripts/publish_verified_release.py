"""Publish frozen Mac and Windows 1.8.1; verify native provenance and all downloads."""
import base64,hashlib,json,os,re,subprocess,sys,zipfile
from pathlib import Path
SOURCE=os.environ['SHIYING_SOURCE'];RUN=os.environ['SHIYING_RUN']
assert re.fullmatch(r'[0-9a-f]{40}',SOURCE) and RUN.isdigit()
PIN='4f0bed8483c35a980315d9c7b3a1d4a1119ad2b2'
MAC_SOURCE='37ced80a2db44d34b79199357f15be242be1461b'
REPO='SJT-bright/shiying-media-workbench';MAC_REPO='SJT-bright/shiying';TAG='v1.8.1';VERSION='1.8.1'
root=Path('snapshot').resolve();assets=Path('assets').resolve();assets.mkdir(exist_ok=True)
def command(args,**kwargs):return subprocess.check_output(args,**kwargs).decode().strip()
def sha(data):return hashlib.sha256(data).hexdigest()
def api(endpoint):return json.loads(command(['gh','api',endpoint]))
assert command(['git','rev-parse','HEAD'],cwd=root)==SOURCE
assert command(['git','rev-parse','HEAD'],cwd=root/'Backend/upstream')==PIN
run=api(f'repos/{REPO}/actions/runs/{RUN}')
assert run['conclusion']=='success' and run['head_sha']==SOURCE
counts={}
for name in ['windows-runtime.json','windows-portable-runtime.json','windows-installed-runtime.json']:
 report=json.loads((assets/name).read_text())
 assert report['passed'] and report['packaged'] and report['platform']=='win32'
 assert report['version']==VERSION and len(report['checks'])>=47 and all(x['passed'] for x in report['checks'])
 assert report['provenance']['sourceCommit']==SOURCE and report['provenance']['upstreamCommit']==PIN
 for source,value in report['provenance']['workerSources'].items():
  raw=(root/'Backend'/source).read_bytes();assert value in {sha(raw),sha(raw.replace(b'\n',b'\r\n'))}
 counts[name]=len(report['checks'])
for line in (assets/'SHA256SUMS.txt').read_text(encoding='utf-8-sig').splitlines():
 digest,name=line.split(None,1);assert sha((assets/name.strip()).read_bytes())==digest.lower()
assert api(f'repos/{MAC_REPO}/git/ref/tags/{TAG}')['object']['sha']==MAC_SOURCE
mac=api(f'repos/{MAC_REPO}/releases/tags/{TAG}');assert not mac['draft']
mac_manifest=json.loads(base64.b64decode(api(f'repos/{MAC_REPO}/contents/source-snapshot.json?ref={TAG}')['content']))
for name,value in mac_manifest['files'].items():
 if name.startswith('Sources/') or (name.startswith('Backend/') and name.endswith('.py')):assert sha((root/name).read_bytes())==value,name
subprocess.run(['gh','release','download',TAG,'--repo',MAC_REPO,'--pattern','Shiying-1.8.1-Mac-arm64.*','--pattern','Shiying-1.8.1-MediaSources.tar.xz','--dir',str(assets)],check=True)
for asset in mac['assets']:
 if asset['name'].startswith('Shiying-1.8.1-Mac-arm64.') or asset['name']=='Shiying-1.8.1-MediaSources.tar.xz':
  file=assets/asset['name'];assert file.stat().st_size==asset['size'] and 'sha256:'+sha(file.read_bytes())==asset['digest']
# The Windows media configuration from this exact successful run accompanies its sources.
with zipfile.ZipFile(assets/'Shiying-1.8.1-Windows-x64.zip') as z:
 for name in ['ffmpeg.exe','ffprobe.exe','config.h','config.mak','source-components.json']:
  member=next(n for n in z.namelist() if n.endswith('resources/Tools/'+name))
  assert sha(z.read(member))==sha((Path('media-tools')/name).read_bytes())
archive=assets/'Shiying-1.8.1-source.zip';prefix='Shiying-1.8.1/'
subprocess.run(['git','archive','--format=zip','--prefix='+prefix,'-o',str(archive),SOURCE],cwd=root,check=True)
files=command(['git','ls-tree','-r','--name-only',PIN],cwd=root/'Backend/upstream').splitlines()
with zipfile.ZipFile(archive,'a',compression=zipfile.ZIP_DEFLATED) as z:
 for name in files:z.writestr(prefix+'Backend/upstream/'+name,subprocess.check_output(['git','show',PIN+':'+name],cwd=root/'Backend/upstream'))
 for name in ['config.h','config.mak','source-components.json']:z.writestr(prefix+'BuildConfigs/Windows/'+name,(Path('media-tools')/name).read_bytes())
 z.writestr(prefix+'SOURCE-RELEASE.json',json.dumps({'sourceCommit':SOURCE,'upstreamCommit':PIN,'version':VERSION,'macBinarySourceCommit':MAC_SOURCE,'publisherToolingCommit':command(['git','rev-parse','HEAD'])},indent=2)+'\n')
with zipfile.ZipFile(archive) as z:assert z.testzip() is None
subprocess.run([sys.executable,str(Path(__file__).with_name('audit_release.py')),str(assets)],check=True)
manifest={p.name:sha(p.read_bytes()) for p in sorted(assets.iterdir()) if p.is_file() and p.name!='SHA256SUMS.txt'}
(assets/'SHA256SUMS.txt').write_text(''.join(f'{value}  {name}\n' for name,value in manifest.items()))
notes=Path('release-notes.md');notes.write_text(f'''拾影 1.8.1：Mac 与 Windows 同步的视频、图文、封面和公众号素材工作台。

新建下载与博主采集提供「采集视频」「采集封面」独立复选框，默认仅视频，可仅封面或同时采集。封面读取平台原图，先临时预览，可右键复制；确认才保存，取消、换输入、离页与关闭清理本轮临时图片。双选先确认封面，再下载视频或加入队列。

- Mac：Apple Silicon、macOS26+，下载 `Shiying-1.8.1-Mac-arm64.dmg` 或 ZIP。
- Windows：Windows10/11 x64，下载 `Shiying-1.8.1-Windows-x64-Setup.exe`；便携 ZIP 解压后双击拾影.exe。
- 完整双端源码：`Shiying-1.8.1-source.zip`，含固定解析子模块、媒体对应源包、Windows确切构建配置；Mac媒体确切对应源码另附MediaSources归档。

保留夜景/日景磨砂玻璃、同位置展开/收回播放、玻璃年月日、紧凑公众号卡片、内嵌文件夹和手动统计。平台字体、窗口边框与玻璃渲染使用各系统实现。

Windows后端210项检查（3项Mac专用检查跳过）、35项桌面检查；原生EXE、便携ZIP和实际安装后各{counts['windows-runtime.json']}项运行流程通过，包括临时封面确认/取消与取消后剪贴板图片字节保持。封面界面流程用合成图片验证；不将其当作所有平台/账号在线下载验收。Mac安装包沿用已验证的1.8.1/build37，与其已公开字节完全一致；共享Mac Sources与Backend逐项哈希匹配。全部发行资产在发布端完整重下载并核对SHA256。

包内包含自己的worker与媒体工具，无需另装Python、Node或FFmpeg。登录仅保留在拾影自身分区；发行包无作者本机登录/媒体/用户资料。Mac为本地签名未Apple公证；Windows无商业证书签名。真实账号登录、不同DPI及显卡表现仍需对应实机确认。

Windows及双端源码：{SOURCE}；Mac二进制源码：{MAC_SOURCE}；解析模块：{PIN}。
''')
existing=subprocess.run(['gh','release','view',TAG,'--repo',REPO,'--json','isDraft,targetCommitish'],capture_output=True,text=True)
if existing.returncode==0:
 release=json.loads(existing.stdout);assert release['isDraft'] and release['targetCommitish']==SOURCE
 subprocess.run(['gh','release','upload',TAG,'--repo',REPO,'--clobber',*[str(p) for p in assets.iterdir() if p.is_file()]],check=True)
 subprocess.run(['gh','release','edit',TAG,'--repo',REPO,'--notes-file',str(notes)],check=True)
else:subprocess.run(['gh','release','create',TAG,'--repo',REPO,'--draft','--target',SOURCE,'--title','拾影 1.8.1 · Mac 与 Windows','--notes-file',str(notes),*[str(p) for p in assets.iterdir() if p.is_file()]],check=True)
verified=Path('downloaded-release');verified.mkdir(exist_ok=True)
subprocess.run(['gh','release','download',TAG,'--repo',REPO,'--dir',str(verified),'--clobber'],check=True)
for name,digest in manifest.items():assert sha((verified/name).read_bytes())==digest
assert (verified/'SHA256SUMS.txt').read_bytes()==(assets/'SHA256SUMS.txt').read_bytes()
subprocess.run(['gh','release','edit',TAG,'--repo',REPO,'--draft=false','--latest'],check=True)
assert api(f'repos/{REPO}/git/ref/tags/{TAG}')['object']['sha']==SOURCE
receipt={'published':True,'sourceCommit':SOURCE,'macSourceCommit':MAC_SOURCE,'release':f'https://github.com/{REPO}/releases/tag/{TAG}','windowsRuntimeChecks':counts,'verifiedAssets':manifest}
Path('publication-verification.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
