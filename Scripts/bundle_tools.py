from pathlib import Path
import subprocess,shutil,os,sys
out=Path(sys.argv[1]); out.mkdir(parents=True,exist_ok=True); libs=out/'lib'; libs.mkdir(exist_ok=True)
seen={}; mappings={}; copies=[]
def deps(path):
 lines=subprocess.check_output(['otool','-L',str(path)],text=True).splitlines()[1:]
 return [l.strip().split(' (')[0] for l in lines]
def copy(src,target):
 src=Path(src).resolve(); key=str(src)
 if key in seen: return seen[key]
 if target.exists():
  if target.name in mappings and mappings[target.name]!=key: raise RuntimeError('library name collision: '+target.name)
 shutil.copy2(src,target); os.chmod(target,0o755); seen[key]=target; mappings[target.name]=key; copies.append((src,target))
 for dep in deps(src):
  if dep.startswith('/opt/homebrew/'):
   copy(dep,libs/Path(dep).name)
  elif dep.startswith('@rpath/'):
   candidate=src.parent/Path(dep).name
   if not candidate.exists(): raise RuntimeError('unresolved rpath '+dep+' in '+str(src))
   copy(candidate,libs/Path(dep).name)
 return target
for name in ['ffmpeg','ffprobe']: copy('/opt/homebrew/bin/'+name,out/name)
for src,target in copies:
 if target.parent==libs: subprocess.run(['install_name_tool','-id','@loader_path/'+target.name,str(target)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 for dep in deps(src):
  if dep.startswith('/opt/homebrew/') or dep.startswith('@rpath/'):
   replacement='@loader_path/'+('' if target.parent==libs else 'lib/')+Path(dep).name
   subprocess.run(['install_name_tool','-change',dep,replacement,str(target)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 subprocess.run(['codesign','--force','--sign','-',str(target)],check=True,capture_output=True)
print('Bundled',len(copies),'media binaries and libraries')
