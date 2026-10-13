import SwiftUI
import AppKit

// 独立视觉验收宿主：只允许隔离测试模式，示例数据不写正式资料，不自动联网。
@main struct GlassPreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: Store
    @StateObject private var batch: BatchStore
    @StateObject private var creator: CreatorStore
    @StateObject private var metrics = WorkStatisticsStore()
    @StateObject private var articles = ArticleStore()
    @StateObject private var covers = CoverCaptureStore()
    @State private var lightAppearance = CommandLine.arguments.contains("--preview-light")

    init() {
        precondition(CommandLine.arguments.contains("--test-mode"))
        precondition(shiyingTestDataRoot(fallback: "")?.path.contains("build/liquid-glass-") == true)
        let s = Store(), b = BatchStore(), c = CreatorStore()
        s.page = "博主采集"
        let folder = StudyCollection(name: "玻璃预览 · 示例", path: b.parentFolder)
        b.collections = [folder]; b.selectedCollectionID = folder.id
        c.urlText = "界面预览 · 示例数据"
        let sec = "MS4wLjABAAAA_SYNTHETIC_DOUYIN_AUTHOR_0001"
        c.handle(["event": "creator", "id": sec, "nickname": "预览示例", "homepage": "https://www.douyin.com/user/\(sec)",
                  "awemeCount": 3], token: c.scanGeneration)
        for index in 1...3 {
            let id = String(7000000000000000000 + index)
            c.handle(["event": "post", "post": ["id": id, "link": "https://www.douyin.com/video/\(id)",
                      "title": ["雾色山湖 · 收集你的灵感", "清晰的层次，安静的工作空间", "保留每一份值得收藏的视频"][index-1],
                      "author": "预览示例", "createdAt": 1791000000, "diggCount": 10000 * index,
                      "collectCount": 2000 * index, "isVideo": true]], token: c.scanGeneration)
            var item = BatchItem(collectionID: folder.id, link: "https://www.douyin.com/video/\(id)", sourceText: "界面示例")
            item.title = "玻璃卡片与配套音轨 · 示例 \(index)"; item.author = "预览示例"
            item.status = .failed; item.error = "视觉预览示例，无实际下载"
            b.items.append(item)
        }
        c.handle(["event": "scan_complete", "complete": true, "reason": "complete", "pages": 1,
                  "received": 3, "awemeCount": 3, "listedCount": 3], token: c.scanGeneration)
        _store = StateObject(wrappedValue: s); _batch = StateObject(wrappedValue: b); _creator = StateObject(wrappedValue: c)
    }

    var body: some Scene {
        WindowGroup("拾影 · 玻璃预览（示例数据）", id: CommandLine.arguments.contains("--preview-compact") ? "compact" : "normal") {
            RootView().environmentObject(store).environmentObject(batch).environmentObject(creator)
                .environmentObject(metrics).environmentObject(articles).environmentObject(covers)
                // 小窗口验收固定内容尺寸，避免历史窗口缩放状态覆盖默认大小。
                .frame(width: CommandLine.arguments.contains("--preview-compact") ? 960 : nil,
                       height: CommandLine.arguments.contains("--preview-compact") ? 700 : nil)
                .preferredColorScheme(lightAppearance ? .light : .dark)
                .onAppear {
                    AppDelegate.store = store; AppDelegate.batch = batch; AppDelegate.creator = creator
                    AppDelegate.metrics = metrics; AppDelegate.articles = articles; AppDelegate.covers = covers
                    store.otherTaskIsBusy = { batch.isRunning || covers.busy }
                    batch.otherTaskIsBusy = { store.busy || covers.busy }
                    creator.otherTaskIsBusy = { covers.busy }
                }
        }
        .defaultSize(width: CommandLine.arguments.contains("--preview-compact") ? 960 : 1240, height: CommandLine.arguments.contains("--preview-compact") ? 700 : 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("预览") {
                Button(lightAppearance ? "切换深色外观" : "切换浅色外观") { lightAppearance.toggle() }
            }
        }
    }
}
