#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
task_root="$PWD"
task_python="$task_root/.venv/bin/python"
if [[ ! -x "$task_python" ]]; then
 print -u2 '采集回归检查失败：缺少 .venv/bin/python，请按 README 安装构建依赖。'
 exit 1
fi
mkdir -p "$task_root/build/creator-regression"
task_run="$(mktemp -d "$task_root/build/creator-regression/run.XXXXXX")"
# Keep receipts; discard only this check's binary and synthetic data.
trap 'rm -rf "$task_run/native-checks" "$task_run/test-data"' EXIT
ulimit -c 0

if ! PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$task_root/Tests:$task_root/Backend:$task_root/Backend/upstream/src" \
 "$task_python" -m unittest -v test_creator_build_gate test_creator_session test_creator_regression test_creator_diagnostics test_worker test_worker_diagnostics test_platform_worker test_photo_worker \
 > "$task_run/backend.txt" 2>&1; then
 cat "$task_run/backend.txt" >&2
 print -u2 "采集回归检查失败：后端检查未通过，打包已停止。记录：$task_run/backend.txt"
 exit 1
fi

if ! swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
 Sources/HistoryRepository.swift Sources/WorkStatisticsCore.swift Sources/CreatorCore.swift Sources/PlatformWebCapture.swift Sources/CreatorStore.swift \
 Tests/CreatorSessionChecks.swift -o "$task_run/native-checks" -framework WebKit \
 > "$task_run/compile.txt" 2>&1; then
 cat "$task_run/compile.txt" >&2
 print -u2 "采集回归检查失败：原生检查编译失败，打包已停止。记录：$task_run/compile.txt"
 exit 1
fi
if ! "$task_run/native-checks" --test-mode --test-data-root "$task_run/test-data" \
 > "$task_run/native.txt" 2>&1; then
 cat "$task_run/native.txt" >&2
 print -u2 "采集回归检查失败：原生登录与状态检查未通过，打包已停止。记录：$task_run/native.txt"
 exit 1
fi
print "采集回归检查通过。记录：$task_run"
