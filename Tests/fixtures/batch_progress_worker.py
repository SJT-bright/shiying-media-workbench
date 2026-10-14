#!/usr/bin/env python3
"""Offline queue fixture, released one item at a time by the native checks."""
import argparse
import json
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("command")
parser.add_argument("--link")
parser.add_argument("--quality")
parser.add_argument("--folder")
args = parser.parse_args()
folder = Path(args.folder)
work_id = args.link.rsplit("/", 1)[-1]


def emit(event, **fields):
    print(json.dumps(dict(event=event, **fields)), flush=True)


emit("metadata", id=work_id, title="离线进度测试 " + work_id)
emit("progress", progress=0.25, detail="正在下载视频")
(folder / (work_id + ".ready")).touch()
deadline = time.monotonic() + 30
while not (folder / (work_id + ".release")).exists():
    if time.monotonic() > deadline:
        raise RuntimeError("Native check did not release the synthetic job")
    time.sleep(0.01)
if (folder / (work_id + ".fail")).exists():
    emit("error", message="离线测试失败")
    raise SystemExit(1)
path = folder / (work_id + ".mp4")
path.write_bytes(b"SYNTHETIC_QUEUE_PROGRESS_ONLY")
emit("complete", path=str(path), video=dict(id=work_id))
