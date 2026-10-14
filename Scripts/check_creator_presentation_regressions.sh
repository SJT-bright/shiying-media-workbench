#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
task_run="$(mktemp -d "$PWD/build/creator-presentation.XXXXXX")"
trap 'rm -rf "$task_run/checks" "$task_run/data"' EXIT
ulimit -c 0
swiftc -swift-version 5 -O -parse-as-library Sources/HistoryRepository.swift Sources/BatchCore.swift Sources/WorkStatisticsCore.swift Sources/CreatorCore.swift Sources/PlatformWebCapture.swift Sources/CreatorStore.swift Tests/CreatorPresentationChecks.swift -o "$task_run/checks" -framework WebKit > "$task_run/compile.txt" 2>&1 || { cat "$task_run/compile.txt" >&2; exit 1; }
"$task_run/checks" --test-mode --test-data-root "$task_run/data" > "$task_run/checks.txt" 2>&1 || { cat "$task_run/checks.txt" >&2; exit 1; }
print "博主展示缓存与筛选更新检查通过。记录：$task_run"
