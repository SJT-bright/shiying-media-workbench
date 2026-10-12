#!/bin/sh
set -eu
task_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
task_target="$1"
task_build="$2"
mkdir -p "$task_build"
task_build="$(CDPATH= cd -- "$task_build" && pwd)"
task_prefix="$task_build/prefix"
mkdir -p "$task_prefix"
python3 "$task_root/Scripts/unpack_media_sources.py" "$task_build/sources"
task_jobs="${SHIYING_BUILD_JOBS:-4}"
export PKG_CONFIG_PATH="$task_prefix/lib/pkgconfig:$task_prefix/lib64/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
task_cross=""
if [ "$task_target" = windows ]; then
 task_cross="x86_64-w64-mingw32-"
 cat > "$task_build/windows.ini" <<'INI'
[binaries]
c = 'x86_64-w64-mingw32-gcc'
cpp = 'x86_64-w64-mingw32-g++'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[properties]
needs_exe_wrapper = true
INI
fi
cd "$task_build/sources/openssl"
if [ ! -f "$task_prefix/lib/libssl.a" ] && [ ! -f "$task_prefix/lib64/libssl.a" ]; then
 if [ "$task_target" = windows ]; then
  perl Configure mingw64 --cross-compile-prefix="$task_cross" --prefix="$task_prefix" --libdir=lib no-shared no-tests no-apps
 else
  perl Configure darwin64-arm64-cc --prefix="$task_prefix" --libdir=lib no-shared no-tests no-apps
 fi
 make -j"$task_jobs" build_libs
 make install_dev
fi
cd "$task_build/sources/x264"
if [ ! -f "$task_prefix/lib/libx264.a" ]; then
 if [ "$task_target" = windows ]; then
  ./configure --prefix="$task_prefix" --enable-static --disable-cli --disable-opencl --cross-prefix="$task_cross" --host=x86_64-w64-mingw32
 else
  ./configure --prefix="$task_prefix" --enable-static --disable-cli --disable-opencl
 fi
 make -j"$task_jobs"
 make install
fi
cd "$task_build/sources/dav1d"
if [ ! -f "$task_prefix/lib/libdav1d.a" ]; then
 if [ "$task_target" = windows ]; then
  meson setup build --prefix="$task_prefix" --libdir=lib --default-library=static --buildtype=release -Denable_tools=false -Denable_tests=false --cross-file="$task_build/windows.ini"
 else
  meson setup build --prefix="$task_prefix" --libdir=lib --default-library=static --buildtype=release -Denable_tools=false -Denable_tests=false
 fi
 meson compile -C build -j "$task_jobs"
 meson install -C build
fi
cd "$task_build/sources/ffmpeg"
task_flags="--prefix=$task_prefix --disable-shared --enable-static --enable-gpl --enable-version3 --enable-libx264 --enable-libdav1d --enable-openssl --disable-doc --disable-debug --disable-ffplay --pkg-config-flags=--static"
if [ "$task_target" = windows ]; then
 ./configure $task_flags --target-os=mingw32 --arch=x86_64 --enable-cross-compile --cross-prefix="$task_cross" --extra-cflags="-I$task_prefix/include" --extra-ldflags="-L$task_prefix/lib -static -static-libgcc" --extra-libs="-lws2_32 -lcrypt32 -lbcrypt"
else
 ./configure $task_flags --extra-cflags="-I$task_prefix/include" --extra-ldflags="-L$task_prefix/lib"
fi
make -j"$task_jobs"
mkdir -p "$task_build/Tools"
if [ "$task_target" = windows ]; then
 cp ffmpeg.exe ffprobe.exe "$task_build/Tools/"
else
 cp ffmpeg ffprobe "$task_build/Tools/"
 chmod 755 "$task_build/Tools/ffmpeg" "$task_build/Tools/ffprobe"
fi
cp config.h ffbuild/config.mak "$task_build/Tools/"
cp "$task_root/Vendor/MediaSources/sources.json" "$task_build/Tools/source-components.json"
cp "$task_build/sources/ffmpeg/COPYING.GPLv3" "$task_build/Tools/FFmpeg-COPYING.GPLv3.txt"
printf '%s\n' "Media tools built: $task_target"
