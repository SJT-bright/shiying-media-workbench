"""Build the same JSON worker for Windows, then prepare desktop resources."""
from pathlib import Path
import argparse,json,os,shutil,struct,subprocess,sys,hashlib
root=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--tools',required=True);a=p.parse_args()
if sys.platform!='win32':raise SystemExit('Build the Windows Python helper on Windows.')
tools=Path(a.tools).resolve()
for name in ['ffmpeg.exe','ffprobe.exe','FFmpeg-COPYING.GPLv3.txt']:
    if not (tools/name).is_file():raise SystemExit('Missing media resource: '+name)
(root/'build/creator-rootqa').mkdir(parents=True,exist_ok=True)
env={**os.environ,'PYTHONUTF8':'1','PYTHONIOENCODING':'utf-8','PYTHONPATH':os.pathsep.join([str(root/'Backend'),str(root/'Backend/upstream/src')]),'POCKET_TOOLS':str(tools)}
subprocess.run([sys.executable,'-m','unittest','discover','-s','Tests','-p','test_*.py'],cwd=root,env=env,check=True)
node=shutil.which('node')
if not node:raise SystemExit('Node.js is required to run desktop regression checks.')
subprocess.run([node,'--test',*[str(p) for p in (root/'Desktop/tests').glob('*.test.cjs')]],cwd=root,check=True)
resources=root/'Desktop/resources';resources.mkdir(exist_ok=True)
subprocess.run([sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onedir','--name','拾影Worker','--paths',str(root/'Backend'),'--paths',str(root/'Backend/upstream/src'),'--distpath',str(root/'build/windows-runtime'),'--workpath',str(root/'build/windows-pyinstaller'),'--specpath',str(root/'build'),'--collect-all','yt_dlp','--hidden-import','cover_worker',str(root/'Backend/worker.py')],check=True)
shutil.copytree(root/'build/windows-runtime/拾影Worker',resources/'worker',dirs_exist_ok=True)
shutil.copytree(tools,resources/'Tools',dirs_exist_ok=True)
licenses=resources/'Licenses';licenses.mkdir(exist_ok=True)
shutil.copy2(root/'Backend/upstream/LICENSE',licenses/'Douyin_API_APACHE2.txt')
subprocess.run([sys.executable,str(root/'Scripts/licenses.py'),str(licenses)],cwd=root,check=True)
(licenses/'media-sources.json').write_bytes((root/'Vendor/MediaSources/sources.json').read_bytes())
shutil.copy2(resources/'Tools/FFmpeg-COPYING.GPLv3.txt',licenses/'FFmpeg-COPYING.GPLv3.txt')
for source,dest in [('GlassWallpaper.png','wallpaper.png'),('GlassWallpaperDay.png','wallpaper-day.png'),('Brand.png','brand.png')]:shutil.copy2(root/'Assets'/source,root/'Desktop/ui'/dest)
icon=root/'Desktop/ui/icon.png'
subprocess.run([str(resources/'Tools/ffmpeg.exe'),'-v','error','-y','-i',str(root/'Assets/Brand.png'),'-vf','scale=256:256','-frames:v','1',str(icon)],check=True)
data=icon.read_bytes();(root/'Desktop/ui/icon.ico').write_bytes(struct.pack('<HHH',0,1,1)+struct.pack('<BBBBHHII',0,0,0,0,1,32,len(data),22)+data)
print('Windows helper and desktop media resources prepared.')

commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
pin=subprocess.check_output(['git','-C',str(root/'Backend/upstream'),'rev-parse','HEAD'],text=True).strip()
if pin!='4f0bed8483c35a980315d9c7b3a1d4a1119ad2b2':raise SystemExit('Unexpected parsing module commit.')
(licenses/'build-provenance.json').write_text(json.dumps({'sourceCommit':commit,'upstreamCommit':pin,'workerSources':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'Backend').glob('*.py')}},indent=2)+'\n',encoding='utf-8')
