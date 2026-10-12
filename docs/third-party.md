# 第三方组件

- `Backend/upstream`：Evil0ctal/Douyin_TikTok_Download_API，Apache-2.0，固定提交 `4f0bed8483c35a980315d9c7b3a1d4a1119ad2b2`；许可随模块和打包资源提供。
- Electron：MIT 与 Chromium 第三方 notices；Electron runtime 自带 `LICENSE` 与 `LICENSES.chromium.html`。
- Python 组件版本固定在 `requirements-build.txt`；`Scripts/licenses.py` 为发行资源生成依赖列表和安装包内许可证。
- FFmpeg 9.0.1 与 x264：本项目媒体工具以 GPL v3 配置构建；对应源包、固定 SHA-256 和构建选项位于 `Vendor/MediaSources` 与 `Scripts/build_media_tools.sh`。
- zlib：1.3.2，固定源包用于 Windows PNG 编解码，保留其许可。
- dav1d 与 OpenSSL：保留源包原始许可；媒体构建同时纳入它们的固定对应源码。
- 背景与品牌图片随拾影源码提供；不包含抓取的用户文章封面或用户视频。

MIT 只覆盖拾影的原创部分，不改变上述第三方许可。

发布扫描仅对 yt-dlp 2026.08.19 的 [listennotes.py](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/yt_dlp/extractor/listennotes.py) 与 [sverigesradio.py](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/yt_dlp/extractor/sverigesradio.py) 中已公开的服务常量作逐文件 SHA-256 匹配。文件有任何修改就重新进行凭据检查，个人路径检查始终执行；其它文件没有豁免。对应行为由隔离测试覆盖。
