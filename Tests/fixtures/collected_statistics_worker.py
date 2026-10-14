#!/usr/bin/env python3
"""Offline batch fixture; the marker file is deliberately not real media."""
import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('command')
parser.add_argument('--link', required=True)
parser.add_argument('--quality')
parser.add_argument('--folder', required=True)
args = parser.parse_args()
name = urlsplit(args.link).path.split('/')[-1]
video = dict(id='synthetic-' + name, title=name, author='合成作者', duration=1)
if name != 'noCounts':
    video['statistics'] = dict(likeCount=7, commentCount=0, recommendCount=12,
        shareCount=3, observedAt=1800000000, source='合成视频号统计')
print(json.dumps(dict(event='metadata', **video)), flush=True)
if name == 'failed':
    print(json.dumps(dict(event='error', message='合成下载失败')), flush=True)
    raise SystemExit(1)
folder = Path(args.folder)
folder.mkdir(parents=True, exist_ok=True)
path = folder / (name + '.mp4')
path.write_bytes(b'SYNTHETIC_BATCH_MEDIA')
print(json.dumps(dict(event='complete', path=str(path), bytes=path.stat().st_size, duration=1, video=video)), flush=True)
