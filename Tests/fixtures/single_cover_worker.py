#!/usr/bin/env python3
"""Local protocol fixture for single-cover transactions; no network or login."""
import argparse
import json
import hashlib
import struct
import time
import zlib
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('command')
p.add_argument('--link')
p.add_argument('--folder')
p.add_argument('--quality')
p.add_argument('--preview-images', action='store_true')
p.add_argument('--preview-cover', action='store_true')
p.add_argument('--video-only', action='store_true')
a = p.parse_args()
folder = Path(a.folder)
root = folder.parent.parent if a.command == 'info' else folder.parent
with (root / 'worker-events.jsonl').open('a') as f:
    f.write(json.dumps({'command': a.command, 'cover': a.preview_cover}) + '\n')
metadata = dict(id='7000000000000000007', title='封面事务测试', author='测试', duration=1,
                width=2, height=3, size=0, cover='https://unused.example/cover.png', mediaKind='video')
print(json.dumps({'event': 'metadata', **metadata}), flush=True)
if a.command == 'info' and not a.preview_cover:
    raise SystemExit(0)
if a.command == 'info':
    album = folder / '封面事务测试_7000000000000000007_封面'
    album.mkdir()
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 3, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress((b'\0' + b'\x20\xa0\xd0' * 2) * 3)) + chunk(b'IEND', b'')
    path = album / '001.png'
    path.write_bytes(png)
    if 'slow' in a.link:
        time.sleep(10)
    if 'fail' in a.link:
        print(json.dumps({'event': 'error', 'message': '合成封面下载失败'}), flush=True)
        raise SystemExit(1)
    complete = dict(mediaKind='video_cover', path=str(album), imagePaths=[str(path)], bytes=len(png), imageSHA256=hashlib.sha256(png).hexdigest())
else:
    assert a.command == 'download' and a.video_only and not a.preview_cover
    path = folder / '合成视频.mp4'
    path.write_bytes(b'SYNTHETIC_VIDEO')
    complete = dict(mediaKind='video', path=str(path), bytes=15)
print(json.dumps({'event': 'complete', 'width': 2, 'height': 3, 'duration': 1, **complete}), flush=True)
