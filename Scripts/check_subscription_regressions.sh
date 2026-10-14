#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
task_run="$(mktemp -d "$PWD/build/subscription-regression.XXXXXX")"
trap 'rm -rf "$task_run/checks" "$task_run/data"' EXIT
ulimit -c 0
task_sources=(Sources/CreatorSubscriptionCore.swift Sources/CreatorSubscriptionStore.swift Sources/SingleDownloadStore.swift Sources/SingleLinkItem.swift Sources/SingleLinkParser.swift Sources/PhotoDraftCore.swift Sources/PhotoClipboard.swift Sources/HistoryRepository.swift Sources/BatchCore.swift Sources/BatchStore.swift Sources/CreatorCore.swift Sources/CreatorStore.swift Sources/PlatformWebCapture.swift Sources/WorkStatisticsCore.swift)
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 $task_sources Tests/CreatorSubscriptionChecks.swift -o "$task_run/checks" -framework AppKit -framework WebKit > "$task_run/compile.txt" 2>&1 || { cat "$task_run/compile.txt" >&2; exit 1; }
SHIYING_SUB_FIXTURE_ROOT="$task_run/data" "$task_run/checks" --test-mode --test-data-root "$task_run/data" > "$task_run/checks.txt" 2>&1 || { cat "$task_run/checks.txt" >&2; exit 1; }
print "博主订阅、增量下载与目录共享回归检查通过。记录：$task_run"
