"""Build the same JSON worker for Windows, then prepare desktop resources."""
from pathlib import Path
import argparse,json,os,shutil,struct,subprocess,sys
root=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--tools',required=True);a=p.parse_args()
if sys.platform!='win32':raise SystemExit('Build the Windows Python helper on Windows.')
resources=root/'Desktop/resources';resources.mkdir(exist_ok=True)
subprocess.run([sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onedir','--name','拾影Worker','--paths',str(root/'Backend'),'--paths',str(root/'Backend/upstream/src'),'--distpath',str(root/'build/windows-runtime'),'--workpath',str(root/'build/windows-pyinstaller'),'--specpath',str(root/'build'),'--collect-all','yt_dlp',str(root/'Backend/worker.py')],check=True)
shutil.copytree(root/'build/windows-runtime/拾影Worker',resources/'worker',dirs_exist_ok=True)
shutil.copytree(Path(a.tools),resources/'Tools',dirs_exist_ok=True)
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
