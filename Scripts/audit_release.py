"""Fail publication on private paths, credentials, or local account data."""
from pathlib import Path
import argparse,getpass,hashlib,os,re,sys,urllib.parse,zipfile
p=argparse.ArgumentParser();p.add_argument('target');p.add_argument('--source',action='store_true');a=p.parse_args();root=Path(a.target)
identifiers=set(filter(None,os.environ.get('SHIYING_PRIVATE_IDENTIFIERS',getpass.getuser()).split(',')))
patterns=[]
for name in identifiers:
    if name in {'runner','runneradmin','root'}:continue
    for value in ['/Users/'+name,'C:\\Users\\'+name]:
        patterns.extend([value.encode(),urllib.parse.quote(value,safe='').encode(),urllib.parse.quote(value).encode()])
secrets=[re.compile(rb'gh[pousr]_[A-Za-z0-9]{30,}'),re.compile(rb'sk-(?:proj-)?[A-Za-z0-9_-]{32,}'),re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')]
issues=[]
# Exact, unmodified source files from yt-dlp 2026.08.19 contain public service
# constants matching generic credential syntax. No modified file is exempt.
published_vendor_sources={
 'resources/worker/_internal/yt_dlp/extractor/listennotes.py':'6250479a8eb67a48693a854bc515a5e4dafae56b243cd7af7b11a8e76cd03ad5',
 'resources/worker/_internal/yt_dlp/extractor/sverigesradio.py':'95c2f63233e80529cb98985b9b6e7120a4f5ab69834f480a629754cd2acf80b8',
}
def check(label,data):
    if any(x.lower() in data.lower() for x in patterns):issues.append((label,'private local path'))
    published=any(label.replace('\\','/').endswith(name) and hashlib.sha256(data).hexdigest()==sha for name,sha in published_vendor_sources.items())
    if not published and b'\0' not in data[:4096] and any(x.search(data) for x in secrets):issues.append((label,'credential marker'))
for file in root.rglob('*'):
    if not file.is_file() or any(part in {'.git','node_modules','.venv','build','__pycache__','.electron-download'} for part in file.relative_to(root).parts):continue
    relative=str(file.relative_to(root))
    if a.source and any(part in {'private-backup','app-data','webkit','.electron-download','resources'} for part in file.relative_to(root).parts):issues.append((relative,'private/generated directory'))
    if a.source and re.fullmatch(r'(?:creator-session.*|history|batch-library|article-library)\.json',file.name):issues.append((relative,'local account/library data'))
    if file.suffix=='.zip':
        with zipfile.ZipFile(file) as z:
            for item in z.infolist():
                if not item.is_dir():check(relative+'!'+item.filename,z.read(item))
    elif file.suffix not in {'.xz','.bz2','.gz','.dmg'}:check(relative,file.read_bytes())
if issues:
    for label,reason in issues:print(reason+': '+label)
    raise SystemExit('Release audit failed.')
print('Release audit passed.')
