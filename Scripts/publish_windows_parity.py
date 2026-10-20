"""Publish a Windows release only after exact-source native package validation."""
import hashlib,json,os,re,subprocess,sys,zipfile
from pathlib import Path
SOURCE=os.environ['SHIYING_SOURCE'];RUN=os.environ['SHIYING_RUN']
assert re.fullmatch(r'[a-f0-9]{40}',SOURCE) and RUN.isdigit()
REPO='SJT-bright/shiying-media-workbench'
VERSION=json.loads((Path('snapshot')/'Desktop/package.json').read_text())['version']
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',VERSION)
TAG='v'+VERSION
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
 assert len(r['checks'])>=80 and all(c['passed'] for c in r['checks'])
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
notes=Path('release-notes.md');notes.write_text(f'''拾影 Windows {VERSION}：GitHub Star 与客户端更新检查。

- 品牌旁新增 ☆ 按钮，打开本项目供用户在 GitHub 点 Star。
- 启动、运行中每6小时自动检查本仓库最新正式发行，回到前台补查到期的检查；侧栏保留手动检查。
- 发现更高版本后显示更新说明与 Windows x64 安装包下载。只接受稳定正式发行、已上传且匹配本仓库/版本的平台包；网络失败保留工作状态并稍后重试。
- 保留多链接独立卡片、封面/图文确认取消、博主订阅增量、播放进度与倍速和本轮队列计数。Windows界面与流程沿用自身已验收主线，不把Mac专用界面能力描述成Windows已有。

[Mac最新1.8.14下载](https://github.com/SJT-bright/shiying/releases/tag/v1.8.14) · [Mac对应源码](https://github.com/SJT-bright/shiying/tree/v1.8.14)

下载 `Shiying-{VERSION}-Windows-x64-Setup.exe` 安装，或解压 `Shiying-{VERSION}-Windows-x64.zip` 后运行拾影.exe。完整对应源码见 `Shiying-{VERSION}-source.zip`，包含固定解析模块、媒体源码和Windows确切配置；本仓库Sources/保留Mac 1.8.6对齐基准，Mac最新源码使用上方独立主线。

旧客户端需要先手动安装一次支持此功能的新版本。以后的更新需要提升版本号、在本仓库发布正式Release并设为Latest，安装包上传完成后发布；只推送源码或替换同版本资产不会提示更新。本功能自动检查并提示下载，安装由用户操作。

Windows原生EXE、便携ZIP与Setup实际安装后三份报告分别通过 {counts['windows-runtime.json']} / {counts['windows-portable-runtime.json']} / {counts['windows-installed-runtime.json']} 项检查。包含真实本地音视频、Star入口、更新横幅和受验证下载地址；新版提示使用合成公开发行元数据，真实平台账号与不同电脑DPI/显卡不由离线CI覆盖。

安装包自带worker与FFmpeg，无需安装Python、Node或FFmpeg。卸载保留用户资料，取消订阅保留媒体。原创源码MIT，第三方保留各自许可，Windows包无商业签名证书。

源码/tag：{SOURCE}；解析模块：{PIN}；原生构建与验收：https://github.com/{REPO}/actions/runs/{RUN} 。所有资产完整重下载并校验SHA256。
''',encoding='utf-8')
existing=subprocess.run(['gh','release','view',TAG,'--repo',REPO,'--json','isDraft,targetCommitish'],capture_output=True,text=True)
if existing.returncode==0:
 r=json.loads(existing.stdout);assert r['isDraft'] and r['targetCommitish']==SOURCE
 subprocess.run(['gh','release','upload',TAG,'--repo',REPO,'--clobber',*[str(p) for p in assets.iterdir() if p.is_file()]],check=True)
 subprocess.run(['gh','release','edit',TAG,'--repo',REPO,'--notes-file',str(notes)],check=True)
else:subprocess.run(['gh','release','create',TAG,'--repo',REPO,'--draft','--target',SOURCE,'--title',f'拾影 {VERSION} · Windows Star与更新检查','--notes-file',str(notes),*[str(p) for p in assets.iterdir() if p.is_file()]],check=True)
download=Path('downloaded-release');download.mkdir(exist_ok=True)
subprocess.run(['gh','release','download',TAG,'--repo',REPO,'--dir',str(download),'--clobber'],check=True)
for name,digest in manifest.items():assert sha((download/name).read_bytes())==digest
assert (download/'SHA256SUMS.txt').read_bytes()==(assets/'SHA256SUMS.txt').read_bytes()
subprocess.run(['gh','release','edit',TAG,'--repo',REPO,'--draft=false','--latest'],check=True)
assert api(f'repos/{REPO}/git/ref/tags/{TAG}')['object']['sha']==SOURCE
receipt={'published':True,'sourceCommit':SOURCE,'release':f'https://github.com/{REPO}/releases/tag/{TAG}','windowsRuntimeChecks':counts,'verifiedAssets':manifest}
Path('publication-verification.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
