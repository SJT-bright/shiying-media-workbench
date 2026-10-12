#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
task_run="$(mktemp -d "$PWD/build/article-regression.XXXXXX")"
trap 'rm -f "$task_run/native-checks" "$task_run/meta-checks" "$task_run/cover-checks"' EXIT
ulimit -c 0
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="Tests:Backend:Backend/upstream/src" .venv/bin/python -m unittest -v test_article_worker test_article_metadata test_article_cover > "$task_run/backend.txt" 2>&1 || { cat "$task_run/backend.txt" >&2; exit 1; }
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 Sources/ArticleCore.swift Sources/ArticleStore.swift Sources/ArticleBrowser.swift Sources/WorkStatisticsCore.swift Sources/CreatorCore.swift Sources/HistoryRepository.swift Sources/FolderBrowserCore.swift Tests/ArticleChecks.swift -o "$task_run/native-checks" -framework AppKit -framework WebKit > "$task_run/compile.txt" 2>&1 || { cat "$task_run/compile.txt" >&2; exit 1; }
"$task_run/native-checks" > "$task_run/native.txt" 2>&1 || { cat "$task_run/native.txt" >&2; exit 1; }
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 Sources/ArticleCore.swift Sources/ArticleStore.swift Sources/ArticleBrowser.swift Sources/WorkStatisticsCore.swift Sources/CreatorCore.swift Sources/HistoryRepository.swift Sources/FolderBrowserCore.swift Tests/ArticleMetadataChecks.swift -o "$task_run/meta-checks" -framework AppKit -framework WebKit -framework CryptoKit > "$task_run/meta-compile.txt" 2>&1 || { cat "$task_run/meta-compile.txt" >&2; exit 1; }
"$task_run/meta-checks" > "$task_run/meta.txt" 2>&1 || { cat "$task_run/meta.txt" >&2; exit 1; }
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 Sources/ArticleCover.swift Sources/ArticleCore.swift Sources/WorkStatisticsCore.swift Sources/CreatorCore.swift Sources/HistoryRepository.swift Tests/ArticleCoverChecks.swift -o "$task_run/cover-checks" -framework AppKit -framework CryptoKit > "$task_run/cover-compile.txt" 2>&1 || { cat "$task_run/cover-compile.txt" >&2; exit 1; }
"$task_run/cover-checks" > "$task_run/cover.txt" 2>&1 || { cat "$task_run/cover.txt" >&2; exit 1; }
print "公众号采集回归检查通过。记录：$task_run"
