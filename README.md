# 拾影 Shiying

视频、图文和公众号素材工作台。Mac 原生 SwiftUI 与 Windows Electron 版放在同一个开源项目中，使用相同的 Python 解析、下载和媒体处理后端。

**[Windows 最新版 1.8.6 下载](https://github.com/SJT-bright/shiying-media-workbench/releases/tag/v1.8.6)** · **[Mac 最新版 1.8.13 下载](https://github.com/SJT-bright/shiying/releases/tag/v1.8.13)** · [双端功能与验证](docs/platform-parity.md) · [构建说明](docs/build.md)

Windows 版以 Mac 1.8.6/build42 的最新界面与流程为基准：深夜城市背景、磨砂玻璃、侧栏和固定底栏、紧凑作品卡片、封面中央展开／收回播放、横向标题、玻璃日期选择和整块按钮响应。系统字体、窗口边框和底层玻璃渲染由各自平台实现。

## 功能

- 新建下载一次解析多条分享，按输入顺序展示独立玻璃卡片；逐条／全部下载，封面和图文分别确认、取消及重试。
- 抖音与B站博主订阅，手动更新只下载本次新增任务；跨全部单条和批量作品查重，文件缺失或失败可补下载，取消订阅保留媒体。
- 卡片常驻播放进度、时间、暂停继续、拖动和0.5×～3×倍速；批量按本轮序号／总数计数，历史累计独立显示。

- 抖音、B站、视频号、小红书分享解析与视频保存，480P／720P／最高画质；保持比例、不放大小源。
- 新建下载与博主采集独立勾选「采集视频」「采集封面」，默认仅视频，支持仅封面与双选。封面直接读取平台原图，先临时预览、右键复制；确认才保存，取消、换输入、离页与关闭清理本轮临时图片。双选先确认封面再下载视频。
- 抖音静态图文先临时预览，复制完整图片后可直接粘贴；确认保存才进入记录，取消清理本次临时资料。
- 博主可访问作品扫描、日期／点赞／收藏／标题筛选、排序及批量队列；暂停、继续与失败重试。平台登录只使用拾影自己的内置网页和独立分区。
- 学习文件夹、备注、同层排序和真实目录移动；目录冲突保留原位置。App 内浏览、选择和新建保存文件夹。
- 本地视频首帧、平台封面和卡片内播放；图文整组预览；按来源搜索已保存作品。
- 手动更新作品统计；公开值与缺失值分别显示，数值变化红色上升／蓝色下降。视频号按喜欢、推荐、评论、转发的实际含义显示。
- 公众号多链接保存正文 Markdown、离线 HTML 和原图；封面打开正文、两行50字简介、横向滚动标题。公众号不提供阅读、点赞、在看等互动数读取。

视频号分享解析使用内置腾讯元宝，当前只保证返回的单作品／可访问范围，不把部分结果标成作者全集。平台验证在内置网页由用户完成。

## 快速开始

Windows 10/11 x64：下载 `Windows-x64-Setup.exe` 安装，或解压 `Windows-x64.zip` 后双击 `拾影.exe`。发布包包含 Python worker 和 FFmpeg，无需另外安装 Python、Node 或 FFmpeg。

Mac：最新版为 **1.8.13/build49**，下载 [DMG](https://github.com/SJT-bright/shiying/releases/download/v1.8.13/Shiying-1.8.13-Mac-arm64.dmg) 或 [ZIP](https://github.com/SJT-bright/shiying/releases/download/v1.8.13/Shiying-1.8.13-Mac-arm64.zip)，需要 Apple Silicon、macOS 26+；[对应开源源码](https://github.com/SJT-bright/shiying/tree/v1.8.13)在独立的 Mac 主线。此 Windows 仓库的 `Sources/` 保留 1.8.6 的历史对齐基准，Mac 后续的灵感浏览器、共享登录与B站统计修复不表示已移植到 Windows。

## 目录

| 目录 | 内容 |
|---|---|
| `Sources/` | Mac 原生界面与资料库 |
| `Desktop/` | Windows 界面、IPC、资料库与打包 |
| `Backend/` | 双端共用下载、文章和统计 worker |
| `Backend/upstream/` | 固定提交的 Apache-2.0 解析模块 |
| `Tests/`, `Desktop/tests/` | 隔离的回归检查 |
| `Vendor/MediaSources/` | FFmpeg 及关联组件的固定源码、校验值 |
| `.github/workflows/` | Windows 原生 worker、EXE、安装包及运行验证 |

Mac 正式资料位于 `~/Library/Application Support/拾影`；Windows 资料位于 `%APPDATA%\拾影`。两台电脑的资料与登录相互独立。卸载程序保留 Windows 用户资料；移除记录保留已保存文件。

## 许可

拾影原创源码采用 MIT。解析模块、Electron、Python 依赖和 FFmpeg 保留各自许可，见 [第三方说明](docs/third-party.md)。仓库包含媒体工具对应的固定源包和构建脚本。仓库不包含用户素材、登录、正式资料库或开发备份。
