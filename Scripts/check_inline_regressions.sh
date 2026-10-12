#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
task_run="$(mktemp -d "$PWD/build/inline-regression.XXXXXX")"
task_host="$task_run/InlineChecks.app"
trap 'rm -f "$task_host/Contents/MacOS/native-checks" "$task_run/sample.mp4" "$task_run/first-frame.h264"' EXIT
ulimit -c 0
mkdir -p "$task_host/Contents/MacOS" "$task_host/Contents/Resources"
cat > "$task_host/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.local.shiying.inline-checks</string><key>CFBundleExecutable</key><string>native-checks</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
# Headless checks need the same Bundle-relative fallback decoder as the real App.
task_tools="$PWD/dist/拾影.app/Contents/Resources/Tools"
if [[ ! -x "$task_tools/ffmpeg" ]]; then
    task_ffmpeg="$(command -v ffmpeg)"
    task_tools="$(dirname "$task_ffmpeg")"
fi
ln -s "$task_tools" "$task_host/Contents/Resources/Tools"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 Sources/InlineVideoPlayer.swift Sources/VideoThumbnail.swift Sources/MediaCoverResolution.swift Sources/WorkStatisticsCore.swift Sources/CreatorCore.swift Sources/HistoryRepository.swift Tests/InlinePlaybackChecks.swift Tests/MediaCoverChecks.swift -o "$task_host/Contents/MacOS/native-checks" -framework SwiftUI -framework AppKit -framework AVKit > "$task_run/compile.txt" 2>&1 || { cat "$task_run/compile.txt" >&2; exit 1; }
"$task_tools/ffmpeg" -hide_banner -loglevel error -nostdin -f lavfi -i "testsrc=size=320x180:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac "$task_run/sample.mp4" > "$task_run/sample.txt" 2>&1
"$task_tools/ffmpeg" -hide_banner -loglevel error -nostdin -i "$task_run/sample.mp4" -map 0:v:0 -c:v copy -bsf:v h264_mp4toannexb -an -f h264 "$task_run/first-frame.h264" >> "$task_run/sample.txt" 2>&1
"$task_host/Contents/MacOS/native-checks" "$task_run/sample.mp4" "$task_run/first-frame.h264" > "$task_run/native.txt" 2>&1 || { cat "$task_run/native.txt" >&2; exit 1; }
print "卡片播放回归检查通过。记录：$task_run"
