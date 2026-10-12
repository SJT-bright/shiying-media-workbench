#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
task_run="$(mktemp -d "$PWD/build/library-regression.XXXXXX")"
trap 'rm -f "$task_run/core-checks" "$task_run/store-checks" "$task_run/photo-checks" "$task_run/draft-checks" "$task_run/single-photo-checks"' EXIT
ulimit -c 0
if ! swiftc -swift-version 5 -O -parse-as-library Sources/BatchCore.swift Tests/CollectionOrganizationChecks.swift \
 -o "$task_run/core-checks" > "$task_run/core-compile.txt" 2>&1; then
 cat "$task_run/core-compile.txt" >&2; print -u2 "文件夹检查编译失败，停止打包：$task_run"; exit 1
fi
if ! "$task_run/core-checks" > "$task_run/core.txt" 2>&1; then
 cat "$task_run/core.txt" >&2; print -u2 "真实移动与恢复检查失败，停止打包：$task_run"; exit 1
fi
if ! swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
 Sources/BatchCore.swift Sources/BatchStore.swift Sources/HistoryRepository.swift Sources/WorkStatisticsCore.swift Sources/CreatorCore.swift \
 Sources/CreatorStore.swift Sources/PlatformWebCapture.swift Tests/CollectionStoreChecks.swift \
 -o "$task_run/store-checks" -framework AppKit -framework WebKit > "$task_run/store-compile.txt" 2>&1; then
 cat "$task_run/store-compile.txt" >&2; print -u2 "文件夹保存检查编译失败，停止打包：$task_run"; exit 1
fi
if ! "$task_run/store-checks" > "$task_run/store.txt" 2>&1; then
 cat "$task_run/store.txt" >&2; print -u2 "文件夹保存与失败保护检查失败，停止打包：$task_run"; exit 1
fi
if ! swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
 Sources/BatchCore.swift Sources/BatchStore.swift Sources/HistoryRepository.swift Sources/WorkStatisticsCore.swift Sources/CreatorCore.swift \
 Sources/CreatorStore.swift Sources/PlatformWebCapture.swift Tests/PhotoStoreChecks.swift \
 -o "$task_run/photo-checks" -framework AppKit -framework WebKit > "$task_run/photo-compile.txt" 2>&1; then
 cat "$task_run/photo-compile.txt" >&2; print -u2 "图文队列检查编译失败，停止打包：$task_run"; exit 1
fi
if ! "$task_run/photo-checks" "$PWD/Tests/fixtures/photo_album_worker.py" --test-mode --test-data-root "$task_run/data" > "$task_run/photo.txt" 2>&1; then
 cat "$task_run/photo.txt" >&2; print -u2 "图文队列保存检查失败，停止打包：$task_run"; exit 1
fi
if ! swiftc -swift-version 5 -O -parse-as-library Sources/PhotoDraftCore.swift Sources/PhotoClipboard.swift Tests/PhotoDraftChecks.swift \
 -o "$task_run/draft-checks" -framework AppKit > "$task_run/draft-compile.txt" 2>&1; then
 cat "$task_run/draft-compile.txt" >&2; print -u2 "临时图文检查编译失败，停止打包：$task_run"; exit 1
fi
if ! "$task_run/draft-checks" > "$task_run/draft.txt" 2>&1; then
 cat "$task_run/draft.txt" >&2; print -u2 "临时图片清理与剪贴板检查失败，停止打包：$task_run"; exit 1
fi
if ! swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
 Sources/SingleDownloadStore.swift Sources/PhotoDraftCore.swift Sources/PhotoClipboard.swift Sources/HistoryRepository.swift \
 Sources/BatchCore.swift Sources/CreatorCore.swift Sources/CreatorStore.swift Sources/PlatformWebCapture.swift Sources/WorkStatisticsCore.swift Tests/SinglePhotoStoreChecks.swift \
 -o "$task_run/single-photo-checks" -framework AppKit -framework WebKit > "$task_run/single-photo-compile.txt" 2>&1; then
 cat "$task_run/single-photo-compile.txt" >&2; print -u2 "单条图文检查编译失败，停止打包：$task_run"; exit 1
fi
if ! "$task_run/single-photo-checks" "$PWD/Tests/fixtures/photo_preview_worker.py" --test-mode --test-data-root "$task_run/single-data" > "$task_run/single-photo.txt" 2>&1; then
 cat "$task_run/single-photo.txt" >&2; print -u2 "单条图文确认与取消检查失败，停止打包：$task_run"; exit 1
fi
print "文件夹、图文队列与临时图片回归检查通过。记录：$task_run"
