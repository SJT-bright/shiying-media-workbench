#!/usr/bin/env python3
"""Offline single-download fixture; no login reads and no network."""
import argparse
import json
import struct
import time
import zlib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('command')
parser.add_argument('--link')
parser.add_argument('--quality')
parser.add_argument('--folder')
parser.add_argument('--preview-images', action='store_true')
parser.add_argument('--video-only', action='store_true')
args = parser.parse_args()
photo = 'video' not in args.link
metadata = {'id': '7000000000000000002', 'title': '离线测试作品', 'author': '测试', 'duration': 0,
            'width': 2, 'height': 3, 'size': 0, 'description': '原文说明'}
if photo:
    metadata.update(mediaKind='image_album', images=[{'url': 'https://unused.example/1', 'width': 2, 'height': 3}] * 2)
print(json.dumps({'event': 'metadata', **metadata}), flush=True)
if args.command == 'info' and not photo:
    raise SystemExit(0)
if 'slow' in args.link:
    time.sleep(30)
folder = Path(args.folder)
if photo:
    assert args.command == 'info' and args.preview_images
    album = folder / '合成图文'; album.mkdir()
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 3, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress((b'\0' + b'\x80\x40\x20' * 2) * 3)) + chunk(b'IEND', b'')
    paths = []
    for index in range(2):
        path = album / f'{index + 1:03d}.png'; path.write_bytes(png); paths.append(str(path))
    if 'fail' in args.link:
        print(json.dumps({'event': 'error', 'message': '合成第二张下载失败'}), flush=True); raise SystemExit(1)
    event = {'path': str(album), 'imagePaths': paths, 'mediaKind': 'image_album', 'bytes': len(png) * 2}
else:
    assert args.command == 'download' and args.video_only
    video = folder / '合成视频.mp4'; video.write_bytes(b'SYNTHETIC_VIDEO'); event = {'path': str(video), 'bytes': 15}
print(json.dumps({'event': 'complete', 'width': 2, 'height': 3, 'duration': 0, 'video': metadata, **event}), flush=True)
