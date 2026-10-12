"""Publish the frozen, verified Windows build; verify downloads before going public."""
import hashlib,json,os,subprocess,sys,zipfile
from pathlib import Path
SOURCE='39d23e7cf22ef2b4a770975ade3bca9d204fcd31'
PIN='4f0bed8483c35a980315d9c7b3a1d4a1119ad2b2'
REPO='SJT-bright/shiying-media-workbench';RUN='38293709745';TAG='v1.8.0'
root=Path('snapshot').resolve();assets=Path('assets').resolve();assets.mkdir(exist_ok=True)
def command(args,**kwargs):return subprocess.check_output(args,**kwargs).decode().strip()
def sha(data):return hashlib.sha256(data).hexdigest()
assert command(['git','rev-parse','HEAD'],cwd=root)==SOURCE
assert command(['git','rev-parse','HEAD'],cwd=root/'Backend/upstream')==PIN
run=json.loads(command(['gh','api',f'repos/{REPO}/actions/runs/{RUN}']))
assert run['conclusion']=='success' and run['head_sha']==SOURCE
for name in ['windows-runtime.json','windows-installed-runtime.json']:
 report=json.loads((assets/name).read_text())
 assert report['passed'] and report['packaged'] and report['platform']=='win32'
 assert report['version']=='1.8.0' and len(report['checks'])==29 and all(x['passed'] for x in report['checks'])
 assert report['provenance']['sourceCommit']==SOURCE and report['provenance']['upstreamCommit']==PIN
 for name,value in report['provenance']['workerSources'].items():
  raw=(root/'Backend'/name).read_bytes();assert value in {sha(raw),sha(raw.replace(b'\n',b'\r\n'))}
for line in (assets/'SHA256SUMS.txt').read_text(encoding='utf-8-sig').splitlines():
 digest,name=line.split(None,1);assert sha((assets/name.strip()).read_bytes())==digest.lower()
archive=assets/'Shiying-1.8.0-source.zip';prefix='Shiying-1.8.0/'
subprocess.run(['git','archive','--format=zip','--prefix='+prefix,'-o',str(archive),SOURCE],cwd=root,check=True)
files=command(['git','ls-tree','-r','--name-only',PIN],cwd=root/'Backend/upstream').splitlines()
with zipfile.ZipFile(archive,'a',compression=zipfile.ZIP_DEFLATED) as z:
 for name in files:z.writestr(prefix+'Backend/upstream/'+name,subprocess.check_output(['git','show',PIN+':'+name],cwd=root/'Backend/upstream'))
 z.writestr(prefix+'SOURCE-RELEASE.json',json.dumps({'sourceCommit':SOURCE,'upstreamCommit':PIN,'version':'1.8.0'},indent=2)+'\n')
with zipfile.ZipFile(archive) as z:assert z.testzip() is None
subprocess.run([sys.executable,str(root/'Scripts/audit_release.py'),str(assets)],check=True)
manifest={p.name:sha(p.read_bytes()) for p in sorted(assets.iterdir()) if p.is_file() and p.name!='SHA256SUMS.txt'}
(assets/'SHA256SUMS.txt').write_text(''.join(f'{value}  {name}\n' for name,value in manifest.items()))
notes=Path('release-notes.md');notes.write_text('''Windows 1.8.0 按 Mac 1.7.5/build35 的最新界面与流程移植。保留夜景磨砂玻璃、紧凑封面卡片、同位置展开／收回播放、横向长标题、文章50字两行摘要、玻璃年月日选择、标题行登录按钮和整块点击区域。

- Windows 安装：`Shiying-1.8.0-Windows-x64-Setup.exe`
- Windows 便携：解压 `Shiying-1.8.0-Windows-x64.zip`，双击 `拾影.exe`
- 双端完整源码：`Shiying-1.8.0-source.zip`，含 Mac `Sources/`、Windows `Desktop/`、固定解析模块和媒体工具对应源码；构建建议使用仓库的 `git clone --recurse-submodules` 命令。

包内含 worker 和 FFmpeg，无需安装 Python、Node 或 FFmpeg。平台登录只保存在拾影自己的分区；公众号不读取互动数，移除记录保留文件。

验证：Windows 后端168项回归（跳过3项Mac专用门槛）、桌面内核22项检查、真实打包 EXE 的29项流程，以及 Setup 实际安装后的29项流程均通过。系统图标与版本信息已验证；全部发布文件已重新下载并核对SHA-256。报告和校验文件附在本页。

Windows包为未签名构建；真实账号登录、不同DPI和显卡表现仍需Windows实机确认。本次发布的Mac部分为原生源码，已有Mac正式应用资料不参与开源包。
''')
existing=subprocess.run(['gh','release','view',TAG,'--repo',REPO,'--json','isDraft,targetCommitish'],capture_output=True,text=True)
if existing.returncode==0:
 release=json.loads(existing.stdout);assert release['isDraft'] and release['targetCommitish']==SOURCE
 subprocess.run(['gh','release','upload',TAG,'--repo',REPO,'--clobber',*[str(p) for p in assets.iterdir() if p.is_file()]],check=True)
else:subprocess.run(['gh','release','create',TAG,'--repo',REPO,'--draft','--target',SOURCE,'--title','拾影 1.8.0 · Windows 与 Mac 双端源码','--notes-file',str(notes),*[str(p) for p in assets.iterdir() if p.is_file()]],check=True)
verified=Path('downloaded-release');verified.mkdir(exist_ok=True)
subprocess.run(['gh','release','download',TAG,'--repo',REPO,'--dir',str(verified),'--clobber'],check=True)
for name,digest in manifest.items():assert sha((verified/name).read_bytes())==digest
assert (verified/'SHA256SUMS.txt').read_bytes()==(assets/'SHA256SUMS.txt').read_bytes()
subprocess.run(['gh','release','edit',TAG,'--repo',REPO,'--draft=false','--latest'],check=True)
assert json.loads(command(['gh','api',f'repos/{REPO}/git/ref/tags/{TAG}']))['object']['sha']==SOURCE
print(json.dumps({'published':True,'sourceCommit':SOURCE,'release':f'https://github.com/{REPO}/releases/tag/{TAG}','verifiedAssets':manifest},indent=2))
