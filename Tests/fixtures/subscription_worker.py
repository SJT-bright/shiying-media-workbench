#!/usr/bin/env python3
"""Offline subscription scan/download fixture; never reads credentials or uses network."""
import json, os, sys, time, uuid, shutil
from pathlib import Path
from urllib.parse import urlsplit
args = sys.argv[1:]
def arg(key, default=None):
 return args[args.index(key)+1] if key in args else default
def emit(event, **kw):print(json.dumps(dict(event=event, **kw)), flush=True)
root=Path(os.environ['SHIYING_SUB_FIXTURE_ROOT']);root.mkdir(parents=True,exist_ok=True)
scenario=json.loads((root/'scenario.json').read_text()) if (root/'scenario.json').exists() else {}
platform=arg('--platform','douyin');home=arg('--link');ident=urlsplit(home).path.strip('/').split('/')[-1]
ids=['7000000000000000001','7000000000000000002','7000000000000000003'] if platform=='douyin' else ['BV1xx411c7mD','BV1yy411c7mD','BV1zz411c7mD']
if args[0]=='scan':
 if scenario.get('slow'):time.sleep(5)
 if scenario.get('startupError'):
  emit('error',message='合成平台拒绝访问');sys.exit(1)
 actual=ident+'_WRONG' if scenario.get('wrong') else ident
 actualhome=f'https://www.douyin.com/user/{actual}' if platform=='douyin' else f'https://space.bilibili.com/{actual}'
 emit('creator',id=actual,nickname='测试博主' if platform=='douyin' else '测试UP主',homepage=actualhome,platform=platform,awemeCount=3)
 for videoid in ids[:scenario.get('count',3)]:
  link=f'https://www.douyin.com/video/{videoid}' if platform=='douyin' else f'https://www.bilibili.com/video/{videoid}'
  emit('post',post=dict(id=videoid,link=link,title='合成新作品 '+videoid,author='测试博主' if platform=='douyin' else '测试UP主',isVideo=True,platform=platform))
 complete=not scenario.get('partial',False)
 emit('scan_complete',complete=complete,reason='complete' if complete else 'limit',pages=1,received=3,cursor=None if complete else '2')
 sys.exit(0 if complete else 1)
folder=Path(arg('--folder'));folder.mkdir(parents=True,exist_ok=True)
videoid=urlsplit(home).path.strip('/').split('/')[-1]
with (root/'downloads.jsonl').open('a') as stream:stream.write(json.dumps({'link':home,'folder':str(folder)})+'\n')
if scenario.get('downloadFail'):
 emit('error',message='合成下载失败');sys.exit(1)
path=folder/('订阅_'+videoid+'_'+uuid.uuid4().hex+'.mp4')
source=os.environ.get('SHIYING_SUB_FIXTURE_VIDEO')
if source:shutil.copyfile(source,path)
else:path.write_bytes(b'SYNTHETIC_SUBSCRIPTION_VIDEO')
emit('metadata',id=videoid,title='合成新作品 '+videoid,author='测试博主',duration=1,width=32,height=32,size=path.stat().st_size)
emit('complete',path=str(path),bytes=path.stat().st_size,width=32,height=32,duration=1,mediaKind='video')
