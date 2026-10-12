#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
task_tools="$1"
task_version="1.8.0"
task_app="$PWD/dist/拾影.app"
mkdir -p "$task_app/Contents/Resources/Tools"
ditto "$task_tools" "$task_app/Contents/Resources/Tools"
export POCKET_TOOLS="$task_app/Contents/Resources/Tools"
./Scripts/build.sh
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $task_version" "$task_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 36" "$task_app/Contents/Info.plist"
cp LICENSE "$task_app/Contents/Resources/Licenses/Shiying-MIT.txt"
cp Vendor/MediaSources/sources.json "$task_app/Contents/Resources/Licenses/media-sources.json"
cp "$task_tools/FFmpeg-COPYING.GPLv3.txt" "$task_app/Contents/Resources/Licenses/"
python3 - "$task_app" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]);p=root/'Contents/Resources/Licenses/components.json'
d=json.loads(p.read_text());d['ffmpeg']='9.0.1 GPL-3.0-or-later; frozen corresponding sources and build scripts supplied';p.write_text(json.dumps(d,indent=2)+'\n')
PY
codesign --force --deep --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
mkdir -p release-assets
ditto -c -k --keepParent "$task_app" "release-assets/Shiying-$task_version-Mac-arm64.zip"
task_dmg="$(mktemp -d "$PWD/build/dmg-source.XXXXXX")"
trap 'rm -rf "$task_dmg"' EXIT
ditto "$task_app" "$task_dmg/拾影.app"
ln -s /Applications "$task_dmg/Applications"
hdiutil create -volname "拾影 $task_version" -srcfolder "$task_dmg" -format UDZO -ov "release-assets/Shiying-$task_version-Mac-arm64.dmg"
python3 Scripts/audit_release.py release-assets
