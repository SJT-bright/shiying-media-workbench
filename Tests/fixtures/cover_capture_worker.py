#!/usr/bin/env python3
"""Offline cover fixture; never parses a URL or reads a session."""
import argparse
import json
import os
from pathlib import Path
import struct
import sys
import time
import zlib


def emit(**fields):
    print(json.dumps(fields, ensure_ascii=False), flush=True)


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    pixels = b"".join(b"\x00" + bytes([40, 130, 210, 255]) * 2 for _ in range(3))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 3, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


parser = argparse.ArgumentParser()
parser.add_argument("command", choices=["cover"])
parser.add_argument("--input", required=True)
parser.add_argument("--folder", required=True)
args = parser.parse_args()
job = Path(args.folder)
payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
assert (job / ".shiying-photo-owner").read_text() == job.name
(job / "worker.pid").write_text(str(os.getpid()))
cover = payload["cover"]
if "flood" in cover:
    print("X" * (300 * 1024), flush=True)
    time.sleep(3)
    sys.exit(2)
if "slow" in cover:
    (job / "started").write_text("worker is running")
    time.sleep(3)
if "fail" in cover:
    emit(event="error", message="fixture 封面下载失败")
    sys.exit(2)
album = job / ("封面_" + payload["id"])
album.mkdir()
image = album / "001.png"
image.write_bytes(png())
emit(event="complete", mediaKind="video_cover", path=str(album), imagePaths=[str(image)],
     width=2, height=3, bytes=image.stat().st_size)
