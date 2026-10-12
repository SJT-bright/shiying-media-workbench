"""Verify frozen source archives before extracting; no mutable downloads."""
from pathlib import Path
import hashlib,json,sys,tarfile
root=Path(__file__).resolve().parent.parent
target=Path(sys.argv[1]);target.mkdir(parents=True,exist_ok=True)
for item in json.loads((root/'Vendor/MediaSources/sources.json').read_text()):
    archive=root/'Vendor/MediaSources'/item['file']
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=item['sha256']:raise SystemExit('Media source checksum mismatch: '+item['file'])
    stem=item['file'].split('-')[0];folder=target/stem
    if folder.exists():continue
    work=target/(stem+'-extract');work.mkdir(exist_ok=True)
    with tarfile.open(archive) as source:source.extractall(work,filter='data')
    children=[p for p in work.iterdir() if p.is_dir()]
    if len(children)!=1:raise SystemExit('Unexpected media source tree')
    children[0].rename(folder);work.rmdir()
