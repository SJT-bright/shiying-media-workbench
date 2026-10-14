#!/usr/bin/env python3
"""Offline ordered-row fixture. It never reads sessions or requests a platform."""
import argparse
import hashlib
import json
import os
import shutil
import struct
import time
import uuid
import zlib
from pathlib import Path
from urllib.parse import urlparse

parser = argparse.ArgumentParser()
parser.add_argument('command', choices=['info', 'download'])
parser.add_argument('--link', required=True)
parser.add_argument('--folder', required=True)
parser.add_argument('--quality')
parser.add_argument('--preview-images', action='store_true')
parser.add_argument('--preview-cover', action='store_true')
parser.add_argument('--video-only', action='store_true')
args = parser.parse_args()
folder = Path(args.folder)
root = folder.parent.parent if args.command == 'info' else folder.parent
root.mkdir(parents=True, exist_ok=True)
with (root / 'worker-events.jsonl').open('a') as stream:
    stream.write(json.dumps({'command': args.command, 'link': args.link,
                             'cover': args.preview_cover}) + '\n')

name = urlparse(args.link).path.strip('/').split('/')[-1]
identity = hashlib.sha256(args.link.encode()).hexdigest()[:19]
album = 'album' in args.link
metadata = dict(id=identity, title='多链接测试 · ' + name, author='测试博主 · ' + name,
                duration=1, width=2, height=3, size=0,
                cover='https://unused.example/cover.png',
                mediaKind='image_album' if album else 'video')
if not album:
    metadata['statistics'] = dict(likeCount=9, commentCount=3, collectCount=None, viewCount=None,
        recommendCount=12, shareCount=1, observedAt=1800000000, source='合成视频号统计')
print(json.dumps({'event': 'metadata', **metadata}), flush=True)

if 'slow' in args.link and ('slowdownload' not in args.link or args.command == 'download'):
    time.sleep(10)
if 'fail' in args.link and ('faildownload' not in args.link or args.command == 'download'):
    print(json.dumps({'event': 'error', 'message': '该条合成解析失败'}), flush=True)
    raise SystemExit(1)
if args.command == 'info' and not args.preview_cover and not album:
    raise SystemExit(0)

if args.command == 'info':
    destination = folder / ('多链接_' + identity + ('_封面' if args.preview_cover else '_图文'))
    destination.mkdir()

    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data
                + struct.pack('>I', zlib.crc32(kind + data)))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 3, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress((b'\0' + b'\x20\xa0\xd0' * 2) * 3))
           + chunk(b'IEND', b''))
    count = 1 if args.preview_cover else 2
    paths = []
    for index in range(count):
        path = destination / f'{index + 1:03d}.png'
        path.write_bytes(png)
        paths.append(str(path))
    complete = dict(mediaKind='video_cover' if args.preview_cover else 'image_album',
                    path=str(destination), imagePaths=paths, bytes=len(png) * count)
    if args.preview_cover:
        complete['imageSHA256'] = hashlib.sha256(png).hexdigest()
else:
    assert args.video_only and not args.preview_cover
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / ('多链接_' + identity + '_' + uuid.uuid4().hex + '.mp4')
    source = os.environ.get('SHIYING_MULTI_FIXTURE_VIDEO')
    if source:
        shutil.copyfile(source, path)
    else:
        path.write_bytes(b'SYNTHETIC_MULTI_VIDEO')
    complete = dict(mediaKind='video', path=str(path), bytes=path.stat().st_size)
print(json.dumps({'event': 'complete', 'width': 2, 'height': 3, 'duration': 1, **complete}), flush=True)
