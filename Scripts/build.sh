#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/拾影.app"
# Login, pagination, recovery and diagnostics must pass before any bundle changes.
"$ROOT/Scripts/check_creator_regressions.sh"
mkdir -p build
"$ROOT/Scripts/check_library_regressions.sh"
"$ROOT/Scripts/check_statistics_regressions.sh"
"$ROOT/Scripts/check_article_regressions.sh"
"$ROOT/Scripts/check_inline_regressions.sh"
"$ROOT/Scripts/check_cover_regressions.sh"
"$ROOT/Scripts/check_multi_regressions.sh"
"$ROOT/Scripts/check_subscription_regressions.sh"
"$ROOT/Scripts/check_creator_presentation_regressions.sh"
mkdir -p build dist
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 Sources/*.swift -o build/拾影 -framework SwiftUI -framework AppKit -framework WebKit -framework AVKit
fp="$(.venv/bin/python Scripts/worker_fingerprint.py)"
stamp="build/runtime/拾影Worker.fingerprint"
worker_bin="build/runtime/拾影Worker/拾影Worker"
old=""
if [[ -f "$stamp" ]]; then old="$(cat "$stamp")"; fi
if [[ ! -x "$worker_bin" || "$old" != "$fp" ]]; then
 rm -rf build/runtime/拾影Worker build/pyinstaller build/拾影Worker.spec
 mkdir -p build/pyinstaller-config
 # 默认缓存在 ~/Library，--clean 会去删它。这里改到仓库 build，避免无权写入用户库时整次打包失败。
 PYINSTALLER_CONFIG_DIR="$ROOT/build/pyinstaller-config" .venv/bin/python -m PyInstaller --noconfirm --clean --onedir --name 拾影Worker --paths Backend/upstream/src --distpath build/runtime --workpath build/pyinstaller --specpath build --collect-all yt_dlp --hidden-import cover_worker Backend/worker.py > build-worker.log 2>&1
 mkdir -p build/runtime
 printf '%s\n' "$fp" > "$stamp"
fi
mkdir -p "$APP/Contents/"{MacOS,Resources,Frameworks}
cp build/拾影 "$APP/Contents/MacOS/拾影"
ditto build/runtime/拾影Worker "$APP/Contents/Resources/worker"
if [[ ! -x "$APP/Contents/Resources/Tools/ffmpeg" ]]; then
 .venv/bin/python Scripts/bundle_tools.py "$APP/Contents/Resources/Tools"
fi
mkdir -p build/AppIcon.iconset
swift Scripts/icon.swift build/AppIcon.png
for size in 16 32 128 256 512; do
 sips -z "$size" "$size" build/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
 twice=$((size * 2))
 sips -z "$twice" "$twice" build/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp build/AppIcon.png "$APP/Contents/Resources/ShiyingBrand.png"
cp Assets/GlassWallpaper.png "$APP/Contents/Resources/GlassWallpaper.png"
cp Assets/GlassWallpaperDay.png "$APP/Contents/Resources/GlassWallpaperDay.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>拾影</string>
<key>CFBundleDisplayName</key><string>拾影</string>
<key>CFBundleExecutable</key><string>拾影</string>
<key>CFBundleIdentifier</key><string>com.local.shiying</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.8.6</string>
<key>CFBundleVersion</key><string>42</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Resources/Licenses"
cp Backend/upstream/LICENSE "$APP/Contents/Resources/Licenses/Douyin_API_APACHE2.txt"
cp README.md "$APP/Contents/Resources/Licenses/README.md"
cp /opt/homebrew/Cellar/ffmpeg/9.0.1_1/COPYING* "$APP/Contents/Resources/Licenses/" 2>/dev/null || true
.venv/bin/python Scripts/licenses.py "$APP/Contents/Resources/Licenses"
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "$APP"
