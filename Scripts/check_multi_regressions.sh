#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
task_run="$(mktemp -d "$PWD/build/multi-regression.XXXXXX")"
trap 'rm -f "$task_run/parser-checks" "$task_run/store-checks"' EXIT
ulimit -c 0
swiftc -swift-version 5 -O -parse-as-library Sources/BatchCore.swift Sources/SingleLinkParser.swift Tests/SingleLinkParserChecks.swift -o "$task_run/parser-checks" > "$task_run/parser-compile.txt" 2>&1 || { cat "$task_run/parser-compile.txt" >&2; exit 1; }
"$task_run/parser-checks" > "$task_run/parser.txt" 2>&1 || { cat "$task_run/parser.txt" >&2; exit 1; }
task_sources=(Sources/SingleDownloadStore.swift Sources/SingleLinkItem.swift Sources/SingleLinkParser.swift Sources/PhotoDraftCore.swift Sources/PhotoClipboard.swift Sources/HistoryRepository.swift Sources/BatchCore.swift Sources/CreatorCore.swift Sources/CreatorStore.swift Sources/PlatformWebCapture.swift Sources/WorkStatisticsCore.swift)
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 $task_sources Tests/MultiDownloadStoreChecks.swift -o "$task_run/store-checks" -framework AppKit -framework WebKit > "$task_run/store-compile.txt" 2>&1 || { cat "$task_run/store-compile.txt" >&2; exit 1; }
"$task_run/store-checks" "$PWD/Tests/fixtures/multi_download_worker.py" --test-mode --test-data-root "$task_run/data" > "$task_run/store.txt" 2>&1 || { cat "$task_run/store.txt" >&2; exit 1; }
print "多链接解析、逐条任务与临时图片事务检查通过。记录：$task_run"
