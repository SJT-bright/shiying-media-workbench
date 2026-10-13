#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
task_run="$(mktemp -d "$PWD/build/cover-regression.XXXXXX")"
trap 'rm -f "$task_run/cover-checks" "$task_run/single-checks"' EXIT
ulimit -c 0
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="Tests:Backend:Backend/upstream/src" .venv/bin/python -m unittest -v test_cover_worker > "$task_run/backend.txt" 2>&1 || { cat "$task_run/backend.txt" >&2; exit 1; }
task_sources=(Sources/SingleDownloadStore.swift Sources/PhotoDraftCore.swift Sources/PhotoClipboard.swift Sources/HistoryRepository.swift Sources/BatchCore.swift Sources/CreatorCore.swift Sources/CreatorStore.swift Sources/PlatformWebCapture.swift Sources/WorkStatisticsCore.swift)
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 $task_sources Sources/CaptureSelection.swift Sources/CoverCaptureStore.swift Tests/CoverCaptureChecks.swift -o "$task_run/cover-checks" -framework AppKit -framework WebKit > "$task_run/compile.txt" 2>&1 || { cat "$task_run/compile.txt" >&2; exit 1; }
"$task_run/cover-checks" "$PWD/Tests/fixtures/cover_capture_worker.py" --test-mode --test-data-root "$task_run/cover-data" > "$task_run/covers.txt" 2>&1 || { cat "$task_run/covers.txt" >&2; exit 1; }
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 $task_sources Tests/SingleCoverStoreChecks.swift -o "$task_run/single-checks" -framework AppKit -framework WebKit > "$task_run/single-compile.txt" 2>&1 || { cat "$task_run/single-compile.txt" >&2; exit 1; }
"$task_run/single-checks" "$PWD/Tests/fixtures/single_cover_worker.py" --test-mode --test-data-root "$task_run/single-data" > "$task_run/single.txt" 2>&1 || { cat "$task_run/single.txt" >&2; exit 1; }
print "封面采集、确认与取消回归检查通过。记录：$task_run"
