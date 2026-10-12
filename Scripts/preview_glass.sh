#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
root="$PWD"
preview="$root/build/liquid-glass-20261004/拾影玻璃预览.app"
mkdir -p "$root/build/liquid-glass-20261004"
.venv/bin/python - <<'PY'
from pathlib import Path
import plistlib, shutil
root=Path('build/liquid-glass-20261004')
text=Path('Sources/App.swift').read_text().split('@main struct PocketApp: App {')[0]
# 只有验收宿主改为独立测试偏好；原源码和现有采集窗口的偏好不变。
text=text.replace('com.local.shiying.testing','com.local.shiying.glasspreview.testing')
(root/'AppDefinitions.swift').write_text(text)
app=root/'拾影玻璃预览.app'
shutil.copytree('dist/拾影.app',app,dirs_exist_ok=True)
p=app/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
info['CFBundleIdentifier']='com.local.shiying.glasspreview'
info['CFBundleDisplayName']='拾影玻璃预览';info['CFBundleName']='拾影玻璃预览'
p.write_bytes(plistlib.dumps(info))
PY
sources=(${(f)"$(rg --files Sources -g '*.swift' -g '!App.swift')"})
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
 "$root/build/liquid-glass-20261004/AppDefinitions.swift" $sources Scripts/GlassPreview.swift \
 -o "$preview/Contents/MacOS/拾影" -framework SwiftUI -framework AppKit -framework WebKit
codesign --force --deep --sign - "$preview"
codesign --verify --deep --strict "$preview"
echo "$preview"
