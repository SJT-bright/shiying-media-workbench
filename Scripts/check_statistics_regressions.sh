#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
task_run="$(mktemp -d "$PWD/build/statistics-regression.XXXXXX")"
trap 'rm -f "$task_run/native-checks" "$task_run/cover-checks"' EXIT
ulimit -c 0
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="Tests:Backend:Backend/upstream/src" .venv/bin/python -m unittest -v test_metrics_worker test_platform_statistics > "$task_run/backend.txt" 2>&1 || { cat "$task_run/backend.txt" >&2; exit 1; }
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 Sources/WorkStatisticsCore.swift Sources/WorkStatisticsStore.swift Sources/HistoryRepository.swift Sources/CreatorCore.swift Sources/CreatorStore.swift Sources/PlatformWebCapture.swift Tests/WorkStatisticsChecks.swift -o "$task_run/native-checks" -framework WebKit > "$task_run/compile.txt" 2>&1 || { cat "$task_run/compile.txt" >&2; exit 1; }
"$task_run/native-checks" > "$task_run/native.txt" 2>&1 || { cat "$task_run/native.txt" >&2; exit 1; }
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 Sources/PlatformCover.swift Sources/HistoryRepository.swift Tests/PlatformCoverChecks.swift -o "$task_run/cover-checks" -framework AppKit -framework SwiftUI > "$task_run/cover-compile.txt" 2>&1 || { cat "$task_run/cover-compile.txt" >&2; exit 1; }
"$task_run/cover-checks" > "$task_run/cover.txt" 2>&1 || { cat "$task_run/cover.txt" >&2; exit 1; }
print "作品统计回归检查通过。记录：$task_run"
