# 双端对齐与验证范围

基准：Mac 1.7.5/build35 已整合的 UI 与业务功能。Windows 1.8.0 是该基准的独立跨平台移植，版本差异不表示 Mac 新增一组未安装功能。

| 流程 | Mac 原生 | Windows 实现 |
|---|---|---|
| 夜景／日景、磨砂玻璃、侧栏与底栏 | SwiftUI/AppKit | 固定图片与 CSS backdrop-filter |
| 小卡片、左封面右作者、中央播放 | AVPlayer | 同位置 HTML video |
| 长标题／正文摘要 | 单行横向标题，文章50字两行 | 同布局与 Unicode 字符规则 |
| 玻璃日历 | 年／月／日面板 | 年／月／日面板，点击日期提交 |
| 平台登录 | 独立 WKWebsiteDataStore | 平台登录各自独立 persist session；文章网页使用临时分区 |
| 单条／图文／批量／文章 | 共用 Python worker | 同一 worker 协议与固定解析模块 |
| 资料组织、真实移动、恢复 | Foundation 事务 | Node 原子保存与移动日志 |
| 公开统计 | 手动刷新、保留未知与旧值 | 同字段；落盘成功后显示变化 |
| 文件定位／复制／本地读取 | Finder、NSPasteboard | Explorer、Electron clipboard、受限媒体协议 |

Windows 不读取 Mac 的用户资料，Windows 登录也不迁移来自其它浏览器的 Cookie。公众号阅读、点赞、在看不接入。平台未公开、验证码、访问范围等业务边界与 Mac 相同。

验证分为后端回归、Mac 宿主的隔离 Electron 流程、Windows CI 真实打包 EXE 启动。远程 CI 不等于用户 Windows 电脑的 DPI、显卡、系统弹窗和真实登录验收；这些项仍需要 Windows 实机。
