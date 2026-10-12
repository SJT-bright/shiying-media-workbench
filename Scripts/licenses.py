from pathlib import Path
import sys,shutil,importlib.metadata,json,subprocess
out=Path(sys.argv[1]); deps=[]
for d in importlib.metadata.distributions():
 name=d.metadata.get('Name','package'); version=d.version
 deps.append({'name':name,'version':version})
 for file in d.files or []:
  if any(x in str(file).lower() for x in ['license','copying','notice']) and '.dist-info' in str(file):
   p=Path(d.locate_file(file))
   if p.is_file():
    dest=out/name/Path(file).name; dest.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(p,dest)
commit=subprocess.check_output(['git','-C','Backend/upstream','rev-parse','HEAD'],text=True).strip()
(out/'components.json').write_text(json.dumps({'upstream':{'repo':'https://github.com/Evil0ctal/Douyin_TikTok_Download_API','commit':commit,'license':'Apache-2.0'},'python':deps,'ffmpeg':'9.0.1 GPL source build' if sys.platform=='win32' else '9.0.1_1 Homebrew build, GPL enabled'},indent=2))
if sys.platform=='win32':
 python_license=Path(sys.base_prefix)/'LICENSE.txt'
 if not python_license.is_file():raise SystemExit('Python license is missing.')
 shutil.copy2(python_license,out/'Python-LICENSE.txt')
for formula in ['ffmpeg','x264','x265','libvpx','libvmaf','lame','opus','svt-av1','dav1d','xz','openssl@3']:
 base=Path('/opt/homebrew/opt')/formula
 for pattern in ['COPYING*','LICENSE*','LICENCE*']:
  for p in base.glob(pattern):
   if p.is_file():
    dest=out/formula/p.name; dest.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(p,dest)
