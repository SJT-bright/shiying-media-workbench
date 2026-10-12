# 构建

先拉取固定解析模块：

```sh
git clone --recurse-submodules https://github.com/SJT-bright/shiying-media-workbench.git
cd shiying-media-workbench
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-build.txt
```

## Mac

Apple Silicon、macOS 26、Xcode 命令行工具；安装 FFmpeg／ffprobe 后执行：

```sh
./Scripts/build.sh
```

输出 `dist/拾影.app`，只生成候选，不自动安装。默认使用 Homebrew 媒体工具；源码自建可执行 `Scripts/build_media_tools.sh mac build/media-mac` 后按 `build_release_mac.sh` 准备资源。

## Windows

Windows 10/11 x64、Python 3.12、Node 24。在 PowerShell 中创建并安装 `.venv`，执行：

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements-build.txt
npm ci --prefix Desktop
.venv\Scripts\python Scripts\build_windows.py --tools C:\path\to\Tools
npm run build:win --prefix Desktop
```

`Tools` 包含 `ffmpeg.exe`、`ffprobe.exe`、`FFmpeg-COPYING.GPLv3.txt`。可在 Linux 以 MinGW 编译固定源包：

```sh
./Scripts/build_media_tools.sh windows build/media-windows
```

所需组件：MinGW x64 GCC/G++、GNU make、Perl、NASM、Meson、Ninja、pkg-config。仓库的 Windows 工作流完整演示该流程。

开发预览：`npm start --prefix Desktop`。Mac 宿主的 Electron 预览使用独立的 `拾影-Windows适配开发` 资料根，不接入 Mac 正式资料。

## 检查

```sh
mkdir -p build/creator-rootqa
PYTHONPATH=Backend:Backend/upstream/src .venv/bin/python -m unittest discover -s Tests -p 'test_*.py'
npm test --prefix Desktop
npm run self-test --prefix Desktop
```

Windows `PYTHONPATH` 使用分号；`SHIYING_PYTHON` 可指定开发 worker 的 Python 路径。`--self-test` 创建临时独立资料和合成登录，执行真实 FFmpeg 转换、音频检查、媒体范围请求、离线原图、日历和取消流程，报告中明确宿主平台和是否为打包程序。通过 Mac 宿主检查不能替代 Windows EXE 验证。
