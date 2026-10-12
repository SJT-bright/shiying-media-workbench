#!/usr/bin/env python3
"""Offline native queue fixture; never reads login or makes network requests."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('command')
parser.add_argument('--link')
parser.add_argument('--quality')
parser.add_argument('--folder')
args = parser.parse_args()
folder = Path(args.folder) / '合成图文'
folder.mkdir(exist_ok=True)
paths = []
for index in range(2):
    path = folder / f'{index + 1:03d}.png'
    path.write_bytes(b'SYNTHETIC_PHOTO')
    paths.append(str(path))
metadata = {'id': '7000000000000000002', 'title': '合成图文', 'author': '离线测试',
            'mediaKind': 'image_album', 'width': 2, 'height': 3, 'duration': 0}
print(json.dumps({'event': 'metadata', **metadata}), flush=True)
print(json.dumps({'event': 'complete', 'path': str(folder), 'imagePaths': paths,
                  'mediaKind': 'image_album', 'width': 2, 'height': 3, 'bytes': 30,
                  'duration': 0, 'video': metadata}), flush=True)
