import SwiftUI
import AppKit

// 拾影主程序（D-SHIYING-INTEGRATE-1003 整合版）。
// 展示层按 docs/ui-migration-20261003/contract.md 迁移为 QQ 排程助手风格：
//   - 旧的 Surface/Pill 与深色硬编码常量（accent/card/muted）已移除，统一改用
//     QQStyle.swift 公共组件（QQTheme / QQPalette / QQDepthSurface / QQIconTile / QQPill 与三种按钮样式）；
//   - RootView = 240 侧栏（QQNavRow）+ 固定页头 + 滚动正文 + 固定任务底栏；
//   - 外观跟随系统明暗（QQPalette），不再强制 dark；
//   - 「下载记录」「使用说明」接 LibraryPages.swift 的 ShiyingHistoryView / ShiyingHelpView。
// 1.2 批量收集桥接（D-BATCH-INTEGRATE-1003）：
//   - RootView/PocketApp 注入独立 BatchStore（BatchStore.swift，队列/持久化归 B）；
//   - 侧栏新增「批量收集」「收集文件夹」两入口，正文接 BatchViews.swift 的
//     ShiyingBatchView / ShiyingStudyLibraryView（音轨裁决：导航用「收集文件夹」，类名不变）；
//   - 固定任务底栏增加批量队列状态/actions（暂停/继续/取消当前/开始），所有页面可见；
//   - 单条与批量互斥：batch 运行时禁单条编辑/下载/菜单，store.busy 时禁批量入口与批量操作；
//   - AppDelegate 退出时同时终止单条 worker 与批量自己的 worker/ffmpeg（batch.shutdown()）。
// 单条任务和图文临时预览由 SingleDownloadStore.swift 管理。

// MARK: - 展示层（QQ 风格）

/// 桌面图标与侧栏共用的 ShiyingBrand.png。进程内只解码一次。
private enum ShiyingBrandImage {
    static let side: CGFloat = 44
    static let cached: NSImage? = {
        guard let url = Bundle.main.url(forResource: "ShiyingBrand", withExtension: "png"),
              let image = NSImage(contentsOf: url),
              image.isValid else { return nil }
        return image
    }()
}

/// 左上角品牌标。缺图时仍是视频框、播放三角和右下下载箭头，不用单独的大箭头。
private struct ShiyingBrandMark: View {
    var body: some View {
        Group {
            if let image = ShiyingBrandImage.cached {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                ShiyingBrandFallback()
            }
        }
        .frame(width: ShiyingBrandImage.side, height: ShiyingBrandImage.side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("视频与下载")
    }
}

private struct ShiyingBrandFallback: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.15))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white, lineWidth: 2.2)
                .frame(width: 24, height: 18)
                .overlay {
                    ShiyingPlayTriangle()
                        .fill(Color.white)
                        .frame(width: 8, height: 9)
                }
                .offset(x: -3, y: -2)
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .overlay {
                    ShiyingDownArrow()
                        .fill(Color(red: 0.12, green: 0.13, blue: 0.15))
                        .frame(width: 7, height: 8)
                }
                .offset(x: 12, y: 12)
        }
    }
}

private struct ShiyingPlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct ShiyingDownArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let mid = rect.midX
        let shaft = rect.width * 0.36
        let head = rect.height * 0.46
        var path = Path()
        path.move(to: CGPoint(x: mid - shaft / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: mid + shaft / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: mid + shaft / 2, y: rect.maxY - head))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - head))
        path.addLine(to: CGPoint(x: mid, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - head))
        path.addLine(to: CGPoint(x: mid - shaft / 2, y: rect.maxY - head))
        path.closeSubpath()
        return path
    }
}

struct RootView: View {
    @StateObject private var subscriptions = CreatorSubscriptionStore()
    @EnvironmentObject var articles: ArticleStore
    @EnvironmentObject var metrics: WorkStatisticsStore
    @EnvironmentObject var store: Store
    @EnvironmentObject var batch: BatchStore
    @EnvironmentObject var creator: CreatorStore
    @EnvironmentObject var covers: CoverCaptureStore
    @Environment(\.colorScheme) private var scheme
    private var palette: QQPalette { QQPalette(scheme) }

    /// 批量队列是否处于活动态（运行/暂停/还有待处理），决定底栏批量区是否常驻显示。
    private var batchActive: Bool { batch.isRunning || batch.isPaused || batch.pendingCount > 0 }

    var body: some View {
        HStack(spacing: 14) {
            sidebar
                .frame(width: 226)
                .disabled(covers.busy)
            VStack(spacing: 12) {
                header
                // 只包正文；pageID 用 store.page，重复点当前页不换 ID。
                // 博主页和批量收集页自己排高度：结果列表单独滚，入口和主按钮不进这条长列表。
                QQPageReveal(pageID: store.page) {
                    pageBody
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.page == "博主采集" || store.page == "批量收集" || store.page == "公众号采集" {
                    // 这两页已有自己的操作区；这里只呈现真正活动的下载任务。
                    if store.busy {
                        taskBar
                    } else if batchActive {
                        batchBar
                    }
                } else {
                    taskBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .background { ShiyingWallpaper() }
        .frame(minWidth: 960, minHeight: 700)
        // 窗口涟漪只挂 Root 最外层一次，不叠到按钮，不改系统面板与菜单。
        .overlay { QQWindowRippleOverlay() }
        .onChange(of: store.text) { _, _ in store.inputChanged() }
        .onDisappear { store.discardPhotoPreviewForClosedWindow(); covers.discard(); ShiyingCardPlayback.shared.stopAll() }
        .onChange(of: covers.draftRecords.map(\.id)) { oldIDs, newIDs in
            if let record = store.viewingAlbum, oldIDs.contains(record.id), !newIDs.contains(record.id) { store.viewingAlbum = nil }
        }
        .onChange(of: store.page) { _, _ in ShiyingCardPlayback.shared.stopAll() }
        .onAppear {
            store.onStatistics = { [weak metrics] post in metrics?.adoptScan([post]) }
            batch.onStatistics = { [weak metrics] post in metrics?.adoptScan([post]) }
            if !store.busy, !batch.isRunning, !covers.busy { _ = batch.useDestination(store.folder) }
        }
        .onChange(of: batch.selectedCollectionID) { _, _ in
            if let path = batch.selectedCollection?.path, store.folder != path { store.folder = path }
        }
        .onChange(of: store.folder) { _, path in
            if batch.selectedCollection?.path != path, !batch.isRunning, !store.busy, !covers.busy {
                _ = batch.useDestination(path)
            }
        }
        .onChange(of: creator.isScanning) { _, running in if !running { metrics.adoptScan(creator.posts) } }
        .sheet(isPresented: $store.choosingFolder) {
            ShiyingFolderPicker(title: "选择保存位置", initialPath: store.folder,
                collections: batch.collections, libraryRoot: batch.parentFolder,
                busy: store.busy || batch.isRunning || covers.busy) { path in
                guard !store.busy, !batch.isRunning, !covers.busy else { return false }
                guard batch.useDestination(path) else { return false }
                store.folder = path
                return true
            }
        }
        .sheet(isPresented: $batch.choosingParentFolder) {
            ShiyingFolderPicker(title: "选择新文件夹的父目录", initialPath: batch.parentFolder,
                collections: batch.collections, libraryRoot: batch.parentFolder,
                busy: store.busy || batch.isRunning || covers.busy) { path in
                guard !store.busy, !batch.isRunning, !covers.busy else { return false }
                batch.parentFolder = path
                batch.notice = "新的收集文件夹会建在：\(URL(fileURLWithPath: path).lastPathComponent)"
                return true
            }
        }
        .sheet(item: $store.viewingAlbum) { record in
            let linkItem = store.linkItems.first { $0.photoDraft?.id == record.id }
            let confirm: (() -> Void)? = store.busy ? nil : linkItem.map { item in { store.confirmLinkItem(item.id) } }
                ?? (store.photoDraft?.id == record.id ? { store.confirmPhotoSave() } : nil)
            let discard: (() -> Void)? = linkItem.map { item in { store.cancelLinkItem(item.id) } }
                ?? (store.photoDraft?.id == record.id ? { store.cancelPhotoSave() } : nil)
            ShiyingAlbumViewer(title: record.title, paths: record.imagePaths ?? [], initialIndex: store.albumInitialIndex,
                onConfirm: confirm, onDiscard: discard,
                confirmTitle: linkItem?.confirmationTitle ?? store.confirmationTitle)
        }
        .sheet(item: $batch.viewingAlbum) { item in
            ShiyingAlbumViewer(title: item.title, paths: item.imagePaths ?? [])
        }
    }

    @ViewBuilder private var pageBody: some View {
        if store.page == "博主采集" {
            ShiyingCreatorView().environmentObject(subscriptions)
                .padding(.horizontal, 2)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.page == "批量收集" {
            ShiyingBatchView()
                .disabled(covers.busy)
                .padding(.horizontal, 2)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.page == "收集文件夹" {
            ShiyingStudyLibraryView().disabled(covers.busy).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                content
                    .padding(.horizontal, 26)
                    .padding(.top, 14)
                    .padding(.bottom, 26)
            }
            .disabled(covers.busy)
        }
    }

    // MARK: 侧栏（240）

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ShiyingBrandMark()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("拾影").font(.system(size: 20, weight: .bold)).foregroundStyle(.primary)
                        Text("素材工作台").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 16)

                navGroup("采集")
                VStack(spacing: 6) {
                    QQNavRow(title: "博主采集",
                             subtitle: creatorNavSubtitle,
                             symbol: "film.stack",
                             selected: store.page == "博主采集",
                             badge: creator.filteredPosts.isEmpty ? nil : creator.filteredPosts.count,
                             prominent: store.page == "博主采集") { store.page = "博主采集" }
                    QQNavRow(title: "公众号采集", subtitle: "文章链接，保存正文与图片",
                             symbol: "doc.text", selected: store.page == "公众号采集",
                             badge: articles.records.isEmpty ? nil : articles.records.filter { $0.status == .saved }.count) { store.page = "公众号采集" }
                    QQNavRow(title: "新建下载", subtitle: "粘贴链接，解析并保存",
                             symbol: "plus.rectangle.on.folder", selected: store.page == "新建下载") { store.page = "新建下载" }
                }

                navGroup("下载")
                QQNavRow(title: "批量收集", subtitle: batch.isRunning ? "队列运行中…" : "多链接或博主主页",
                         symbol: "square.and.arrow.down.on.square", selected: store.page == "批量收集",
                         badge: batchActive ? batch.pendingCount : nil) { store.page = "批量收集" }
                    .disabled(store.busy)

                navGroup("资料")
                VStack(spacing: 6) {
                    QQNavRow(title: "收集文件夹", subtitle: batch.collections.isEmpty ? "按主题整理视频与音轨" : "\(batch.collections.count) 个主题",
                             symbol: "folder", selected: store.page == "收集文件夹") { store.page = "收集文件夹" }
                        .disabled(store.busy)
                    QQNavRow(title: "下载记录", subtitle: "每一次保存，都能在这里找到",
                             symbol: "clock.arrow.circlepath", selected: store.page == "下载记录",
                             badge: store.records.isEmpty ? nil : store.records.count) { store.page = "下载记录" }
                    QQNavRow(title: "使用说明", subtitle: "三步保存作品",
                             symbol: "questionmark.circle", selected: store.page == "使用说明") { store.page = "使用说明" }
                }
                if store.busy {
                    Label("单条任务处理中，批量入口暂不可用", systemImage: "hourglass")
                        .font(.system(size: 10))
                        .foregroundStyle(QQTheme.orange)
                        .padding(.top, 8)
                }

                QQDepthSurface(radius: 14, padding: 12, inset: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("本地收藏", systemImage: "externaldrive")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(store.completed.count + batch.completedCount)")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text("个作品").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(sizeText(store.completed.reduce(0) { $0 + $1.bytes } + batch.items.filter { $0.status == .completed }.reduce(0) { $0 + $1.bytes }))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button { store.openFolder() } label: {
                            Label("打开保存文件夹", systemImage: "folder")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(QQGhostPressStyle(tint: QQTheme.cyan, radius: 8, glass: true))
                        .foregroundStyle(QQTheme.cyan)
                    }
                }
                .padding(.top, 16)

                HStack(spacing: 6) {
                    Circle().fill(QQTheme.mint).frame(width: 5, height: 5)
                    Text("文件保存在你的电脑").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.top, 12)
                ShiyingThemePicker().padding(.top, 14)
                Text("拾影 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · Apple Silicon")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .padding(.top, 4)
            }
            .padding(16)
            .padding(.top, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .shiyingGlass(radius: 26, tint: QQTheme.cyan.opacity(0.015))
    }

    private var creatorNavSubtitle: String {
        if creator.isScanning { return "正在扫描" }
        if !creator.creatorName.isEmpty { return creator.creatorName }
        return "主页、筛选、下载"
    }

    private func navGroup(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    // MARK: 固定页头

    private var header: some View {
        HStack(spacing: 10) {
            QQIconTile(symbol: pageSymbol, size: 32, gradient: QQTheme.gradient(for: store.page))
            VStack(alignment: .leading, spacing: 1) {
                Text(store.page).font(.system(size: 18, weight: .bold)).foregroundStyle(.primary).lineLimit(1)
                Text(pageSubtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.page == "公众号采集" {
                liveCount("已保存", articles.records.filter { $0.status == .saved }.count)
                liveCount("待保存", articles.records.filter { $0.status != .saved && $0.status != .failed }.count)
                liveCount("失败", articles.records.filter { $0.status == .failed }.count)
            } else {
                liveCount("已保存", store.completed.count + batch.completedCount)
                liveCount("待处理", batch.pendingCount)
                liveCount("符合", creator.filteredPosts.count)
            }
            QQPill(text: readiness.text, tint: readiness.tint, symbol: readiness.symbol)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .shiyingGlass(radius: 22)
    }

    private func liveCount(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(value)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var readiness: (text: String, tint: Color, symbol: String) {
        if store.busy { return (store.isMultiLinkMode ? "多条处理中" : "单条下载中", QQTheme.amber, "arrow.down.circle") }
        if articles.busy { return ("公众号采集中", QQTheme.teal, "doc.text") }
        if creator.isScanning { return ("正在采集", QQTheme.mint, "dot.radiowaves.left.and.right") }
        if batch.isRunning { return ("队列运行中", QQTheme.cyan, "square.stack.3d.down.right") }
        if batch.isPaused { return ("队列已暂停", QQTheme.amber, "pause.circle") }
        return ("空闲", QQTheme.teal, "checkmark.seal")
    }

    private var pageSymbol: String {
        switch store.page {
        case "博主采集": return "film.stack"
        case "公众号采集": return "doc.text"
        case "批量收集": return "square.and.arrow.down.on.square"
        case "收集文件夹": return "folder"
        case "下载记录": return "clock.arrow.circlepath"
        case "使用说明": return "questionmark.circle"
        default: return "plus.rectangle.on.folder"
        }
    }

    private var pageSubtitle: String {
        switch store.page {
        case "博主采集": return "抖音 · B站 · 视频号 · 小红书"
        case "公众号采集": return "粘贴文章链接，保存正文、离线网页和原图。"
        case "新建下载": return "把想留住的视频与图文，收进自己的收藏。"
        case "批量收集": return "多链接导入，或从博主主页筛选后下载。"
        case "收集文件夹": return "归类素材，记录文案、标题与开头钩子的学习重点。"
        case "下载记录": return "每一次保存，都能在这里找到。"
        default: return "粘贴链接，选择画质，保存到你的 Mac。"
        }
    }

    // MARK: 正文

    @ViewBuilder private var content: some View {
        switch store.page {
        case "新建下载": composer
        case "公众号采集": ShiyingArticleView()
        case "收集文件夹": ShiyingStudyLibraryView()
        case "下载记录":
            // 互斥补充：旧历史页的 retry 只 guard store.busy，批量运行时会放开第二单条 worker；
            // 在本调用点整页禁用旧动作（浏览/滚动不受影响）。Store 业务段不改。
            ShiyingHistoryView().disabled(batch.isRunning)
        default: ShiyingHelpView()
        }
    }

    private var composer: some View {
        VStack(spacing: 16) {
            if let issue = store.historyIssue { errorBanner(issue) }
            linkCard
            if store.isMultiLinkMode {
                ShiyingMultiDownloadList()
            } else if let video = store.video { preview(video) }
            if store.captureVideo && store.video?.isAlbum != true { qualityCard }
            folderCard
            if let error = store.error { errorBanner(error) }
            if !store.isMultiLinkMode {
                if store.busy { progressCard }
                if let draft = store.photoDraft { pendingPhotos(draft) }
                if let message = store.photoMessage {
                    Label(message, systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                if let result = store.result { success(result) }
            }
        }
    }

    private var linkCard: some View {
        QQDepthSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    QQIconTile(symbol: "link", size: 34)
                    Text("作品链接").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Button { store.paste() } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(QQSoftButtonStyle())
                    .disabled(store.busy || batch.isRunning)
                }
                ZStack(alignment: .topLeading) {
                    if store.text.isEmpty {
                        Text("粘贴一条或多条抖音、B站、视频号或小红书链接／分享文案…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary.opacity(0.7))
                            .padding(11)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $store.text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .accessibilityLabel("一条或多条视频、图文链接与分享文案")
                }
                .frame(height: 104)
                .shiyingGlass(radius: 12, inset: true)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hairline, lineWidth: 0.9))
                .qqControlMotion(tint: QQTheme.cyan)
                .disabled(store.busy || batch.isRunning)
                CaptureOptionsView(video: $store.captureVideo, cover: $store.captureCover,
                                   disabled: store.busy || batch.isRunning || covers.busy)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.linkSummary.isEmpty ? "支持多条链接与分享文案，按输入顺序展示，重复链接只保留一条。" : store.linkSummary)
                        Text(store.captureCover ? "封面解析后自动临时下载，可右键复制，确认后保存" : "图文解析后自动临时下载，可右键复制，确认后保存")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("解析预览") { store.preview() }
                        .buttonStyle(QQSoftButtonStyle())
                        .disabled(store.busy || batch.isRunning || !store.captureSelectionValid || store.text.isEmpty)
                }
            }
        }
    }

    @ViewBuilder private func preview(_ v: Video) -> some View {
        if store.captureCover {
            let draft = store.photoDraft
            ShiyingPhotoPreview(title: v.title, author: v.author,
                images: [PhotoPreview(url: v.cover ?? "", width: draft?.width, height: draft?.height)], paths: store.photoPaths,
                onCopy: { store.copyPhoto($0) }, onView: { index in
                    if let record = store.photoDraft ?? store.result, record.isCover { store.play(record, initialIndex: index) }
                }, kindTitle: "封面")
        } else if v.isAlbum {
            ShiyingPhotoPreview(title: v.title, author: v.author, images: v.images ?? [], paths: store.photoPaths,
                onCopy: { store.copyPhoto($0) }, onView: { index in
                    if let record = store.photoDraft ?? store.result { store.play(record, initialIndex: index) }
                })
        } else { QQDepthSurface(padding: 16) {
            HStack(alignment: .center, spacing: 16) {
                AsyncImage(url: v.cover.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            QQTheme.cyan.opacity(scheme == .dark ? 0.25 : 0.10)
                            Image(systemName: "film").font(.system(size: 26)).foregroundStyle(QQTheme.cyan)
                        }
                    }
                }
                .frame(width: 148, height: 94)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hairline, lineWidth: 0.8))

                VStack(alignment: .leading, spacing: 8) {
                    Text(v.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text(v.author).font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        QQPill(text: v.time, tint: QQTheme.cyan, symbol: "clock")
                        QQPill(text: v.dimensions, tint: QQTheme.blue, symbol: "rectangle.expand.vertical")
                        if v.size > 0 { QQPill(text: (store.result == nil ? "最高约 " : "文件大小 ") + sizeText(v.size), tint: QQTheme.teal, symbol: "externaldrive") }
                    }
                }
                Spacer(minLength: 0)
            }
        } }
    }

    private var qualityCard: some View {
        QQDepthSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    QQIconTile(symbol: "slider.horizontal.3", size: 34, gradient: QQTheme.cool)
                    Text("导出画质").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    QQPill(text: "按需保存，保持原比例", tint: QQTheme.slate, variant: .neutral, compact: true)
                }
                HStack(spacing: 12) {
                    ForEach(Quality.allCases) { q in
                        qualityOption(q)
                    }
                }
                Text(store.quality == .original
                     ? "最高画质保留视频源，不重新压缩。"
                     : "\(store.quality.title) 按短边导出，保留横竖比例；原视频较小时不放大。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func qualityGradient(_ q: Quality) -> LinearGradient {
        switch q {
        case .compact: return QQTheme.success
        case .balanced: return QQTheme.brand
        case .original: return QQTheme.warm
        }
    }

    private func qualityOption(_ q: Quality) -> some View {
        let selected = store.quality == q
        return Button { store.quality = q } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    QQIconTile(symbol: q.icon, size: 30, gradient: qualityGradient(q))
                    Spacer(minLength: 6)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? QQTheme.cyan : Color.secondary.opacity(0.45))
                }
                Text(q.title).font(.system(size: 16, weight: .bold)).foregroundStyle(.primary)
                Text(q.detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shiyingGlass(radius: 18, tint: selected ? QQTheme.cyan.opacity(0.12) : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? QQTheme.cyan.opacity(0.45) : palette.hairline,
                                  lineWidth: selected ? 1.2 : 0.9)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(QQGhostPressStyle(tint: QQTheme.cyan, radius: 18))
        .disabled(store.busy || batch.isRunning)
        .accessibilityLabel("选择 \(q.title)")
    }

    private var folderCard: some View {
        QQDepthSurface(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    QQIconTile(symbol: "folder.fill", size: 34, gradient: QQTheme.warm)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("保存位置").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                        Text(shortFolder)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(store.folder)
                    }
                    Spacer(minLength: 12)
                    Button("更改…") { store.chooseFolder() }
                        .buttonStyle(QQSoftButtonStyle())
                        .disabled(store.busy || batch.isRunning)
                }
                Toggle("完成后在 Finder 中显示", isOn: $store.revealOnComplete)
                    .font(.system(size: 11))
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.secondary)
                    .qqControlMotion(tint: QQTheme.cyan)
            }
        }
    }

    private var shortFolder: String {
        store.folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            QQIconTile(symbol: "exclamationmark.triangle.fill", size: 32, gradient: QQTheme.danger)
            Text(message).font(.system(size: 12)).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .shiyingGlass(radius: 18, tint: QQTheme.rose.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(QQTheme.rose.opacity(0.28), lineWidth: 0.9)
        }
    }

    private var progressCard: some View {
        QQDepthSurface(accent: QQTheme.cyan) {
            VStack(spacing: 12) {
                HStack {
                    Text(store.detail).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text("\(Int(store.overall * 100))%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(QQTheme.cyan)
                        .monospacedDigit()
                }
                ProgressView(value: store.overall).tint(QQTheme.cyan)
                HStack(spacing: 6) {
                    ForEach([("parse", "解析"), ("download", "下载"), ("export", "导出"), ("verify", "检查")], id: \.0) { s in
                        if store.stage == s.0 {
                            QQPill(text: s.1, tint: QQTheme.cyan, variant: .emphasis, compact: true)
                        } else {
                            QQPill(text: s.1, tint: QQTheme.slate, variant: .neutral, compact: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if store.stage == "download" {
                    HStack {
                        Text("\(sizeText(store.received)) / \(sizeText(store.total))")
                        Spacer(minLength: 12)
                        Text("\(sizeText(Int64(store.speed))) / 秒")
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func pendingPhotos(_ r: Record) -> some View {
        QQDepthSurface(accent: QQTheme.cyan) {
            HStack(spacing: 12) {
                QQIconTile(symbol: "photo.on.rectangle", size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(r.isCover ? "封面已临时下载" : "\(r.imagePaths?.count ?? 0) 张图片已临时下载").font(.system(size: 14, weight: .semibold))
                    Text("右键复制需要的图片。确认保存才入库；取消会清理本次临时图片。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看图片") { store.play(r) }.buttonStyle(QQSoftButtonStyle()).disabled(store.busy)
            }
        }
    }

    private func success(_ r: Record) -> some View {
        HStack(spacing: 14) {
            QQIconTile(symbol: "checkmark.circle.fill", size: 40, gradient: QQTheme.success)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.isCover ? "封面已保存" : r.isAlbum ? "\(r.imagePaths?.count ?? 0) 张图片已保存" : "视频已保存").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Text(r.isAlbum ? "按原顺序保存 · \(sizeText(r.bytes))" : "\(r.width) × \(r.height) · \(sizeText(r.bytes))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 12)
            Button { store.play(r) } label: {
                Label(r.isAlbum ? "查看图片" : "播放", systemImage: r.isAlbum ? "photo.on.rectangle" : "play.fill").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(QQSoftButtonStyle())
            Button { store.reveal(r) } label: {
                Label("在 Finder 中显示", systemImage: "folder").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(QQSoftButtonStyle())
        }
        .padding(16)
        .shiyingGlass(radius: 20, tint: QQTheme.teal.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(QQTheme.teal.opacity(0.28), lineWidth: 0.9)
        }
    }

    // MARK: 固定任务底栏（所有页面常驻；批量队列活动时上方追加队列区，切页也能看到进度）

    private var taskBar: some View {
        VStack(spacing: 0) {
            if batchActive { batchBar }
            if batchActive { Divider().overlay(palette.hairline) }
            VStack(spacing: 10) {
                if store.busy {
                    ProgressView(value: store.overall).tint(QQTheme.cyan)
                }
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(taskTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
                        Text(taskHint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                    taskActions
                        .layoutPriority(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
        }
        .shiyingGlass(radius: 22)
    }

    // 批量队列区：进度 + 计数 + 队列操作。单条 store.busy 时不提供批量操作（防第二 worker），只显示状态。
    private var batchBar: some View {
        VStack(spacing: 8) {
            ProgressView(value: batch.progress).tint(QQTheme.violet)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(batchTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
                    Text("全部任务：待 \(batch.pendingCount) · 完成 \(batch.completedCount) · 失败 \(batch.failedCount) · 共 \(batch.totalCount)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                }
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                batchActions
                    .layoutPriority(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var batchActions: some View {
        HStack(spacing: 8) {
        if store.busy || covers.busy {
            Text(covers.busy ? "封面任务处理中" : "单条任务处理中").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if batch.isRunning {
            Button { batch.pause() } label: {
                Label("暂停", systemImage: "pause.fill").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.amber))
            Button { batch.cancelCurrent() } label: {
                Label("取消当前", systemImage: "stop.fill").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose))
        } else if batch.isPaused {
            Button { batch.resume() } label: {
                Label("继续", systemImage: "play.fill").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.teal))
        } else {
            Button { batch.start() } label: {
                Label("开始批量", systemImage: "play.fill").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.teal))
        }
        }
    }

    private var batchTitle: String {
        if batch.isRunning { return batch.detail.isEmpty ? "批量队列运行中" : batch.detail }
        if batch.isPaused { return "批量队列已暂停" }
        return "批量队列待开始（\(batch.pendingCount) 条等待）"
    }

    private var taskTitle: String {
        if store.busy { return store.detail.isEmpty ? "正在处理" : store.detail }
        if store.page == "博主采集" {
            if creator.isScanning { return creator.detail.isEmpty ? "正在采集" : creator.detail }
            if !creator.creatorName.isEmpty { return creator.creatorName }
            return "博主采集"
        }
        if store.page == "新建下载" {
            if store.isMultiLinkMode { return "按顺序处理 \(store.linkItems.count) 条作品" }
            if let r = store.photoDraft { return r.isCover ? "临时封面，等待确认保存" : "\(r.imagePaths?.count ?? 0) 张临时图片，等待确认" }
            if let r = store.result { return r.isAlbum ? "\(r.imagePaths?.count ?? 0) 张图片已保存" : "视频已保存" }
            if !store.captureSelectionValid { return "请选择采集视频或封面" }
            if store.captureCover { return store.captureVideo ? "准备采集视频与封面" : "准备临时下载封面" }
            return store.video?.isAlbum == true ? "准备保存整组图片" : "准备保存这段精彩"
        }
        return "准备就绪"
    }

    private var taskHint: String {
        if store.isMultiLinkMode && store.page == "新建下载" {
            let saved = store.linkItems.filter(\.isCompleted).count
            let waiting = store.linkItems.filter(\.canConfirm).count
            let failed = store.linkItems.filter { $0.error != nil }.count
            return "已保存 \(saved) · 待确认 \(waiting) · 失败 \(failed)" + (store.busy ? " · 可随时取消" : "")
        }
        if store.photoDraft != nil && !store.busy { return "可右键复制 · 取消保存会清理临时图片" }
        if store.busy { return "整体进度 \(Int(store.overall * 100))% · 你可以随时取消" }
        if store.page == "博主采集" {
            return "符合 \(creator.filteredPosts.count) · 已选 \(creator.selectedPosts.count) · 未知字段 \(creator.unknownFieldCount)"
        }
        if store.page == "新建下载" { return "文件名自动整理 · 同名文件自动保留" }
        return "切换到「新建下载」粘贴链接即可开始"
    }

    // 忙时：编辑/选择/下载全部禁用，只留取消；空闲时按页面给动作。
    @ViewBuilder private var taskActions: some View {
        if store.busy {
            Button { store.cancel() } label: {
                Label(store.cancelling ? "正在取消…" : store.isMultiLinkMode ? "取消全部" : "取消任务", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose))
            .disabled(store.cancelling)
        } else if store.page == "新建下载" {
            if store.isMultiLinkMode {
                ShiyingMultiDownloadActions()
            } else if store.photoDraft != nil {
                Button("取消保存") { store.cancelPhotoSave() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose))
                    .disabled(batch.isRunning)
                Button(store.confirmationTitle) { store.confirmPhotoSave() }.buttonStyle(QQDepthButtonStyle())
                    .disabled(batch.isRunning)
            } else {
            if let r = store.result {
                Button { store.play(r) } label: {
                    Label(r.isAlbum ? "查看图片" : "播放", systemImage: r.isAlbum ? "photo.on.rectangle" : "play.fill").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(QQSoftButtonStyle())
                Button { store.reveal(r) } label: {
                    Label("显示文件", systemImage: "folder").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(QQSoftButtonStyle())
            }
            Button { store.download() } label: {
                Label(store.captureCover && !store.captureVideo ? "临时下载封面" : "开始下载", systemImage: "arrow.down.to.line")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(QQDepthButtonStyle())
            .disabled(store.busy || batch.isRunning || !store.captureSelectionValid || store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            }
        } else {
            Button { store.page = "新建下载" } label: {
                Label("新建下载", systemImage: "plus.rectangle.on.folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(QQSoftButtonStyle())
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var store: Store?
    static var batch: BatchStore?
    static var creator: CreatorStore?
    static var metrics: WorkStatisticsStore?
    static var articles: ArticleStore?
    static var covers: CoverCaptureStore?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            ShiyingCardPlayback.shared.stopAll()
            ShiyingThumbnailProcesses.cancelAll()
            AppDelegate.batch?.shutdown(); AppDelegate.creator?.shutdown(); AppDelegate.metrics?.shutdown(); AppDelegate.articles?.shutdown()
            if AppDelegate.store != nil || AppDelegate.covers != nil {
                var waiting = 2
                let finished: () -> Void = {
                    waiting -= 1
                    if waiting == 0 { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
                }
                if let store = AppDelegate.store { store.shutdown(completion: finished) } else { finished() }
                if let covers = AppDelegate.covers { covers.shutdown(completion: finished) } else { finished() }
                return .terminateLater
            }
            AppDelegate.store?.shutdown()
            return .terminateNow
        }
    }
}
@main struct PocketApp: App {
    @AppStorage(ShiyingTheme.storageKey, store: ShiyingTheme.defaults) private var appearance = ShiyingTheme.night.rawValue
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()
    @StateObject private var batch = BatchStore()
    @StateObject private var creator = CreatorStore()
    @StateObject private var metrics = WorkStatisticsStore()
    @StateObject private var articles = ArticleStore()
    @StateObject private var covers = CoverCaptureStore()
    var body: some Scene {
        WindowGroup("拾影") {
            RootView().environmentObject(store).environmentObject(batch).environmentObject(creator).environmentObject(metrics).environmentObject(articles).environmentObject(covers)
                .preferredColorScheme(ShiyingTheme.resolve(appearance).colorScheme)
                .onAppear {
                    AppDelegate.store = store; AppDelegate.batch = batch; AppDelegate.creator = creator
                    AppDelegate.metrics = metrics; AppDelegate.articles = articles; AppDelegate.covers = covers
                    store.otherTaskIsBusy = { batch.isRunning || covers.busy || creator.isScanning }
                    batch.otherTaskIsBusy = { store.busy || covers.busy || creator.isScanning }
                    creator.otherTaskIsBusy = { covers.busy || store.busy || batch.isRunning }
                }
        }
            .defaultSize(width: 1100, height: 900)
            .windowStyle(.hiddenTitleBar)
            .commands { CommandGroup(replacing: .newItem) { Button("新建下载") { store.page = "新建下载" }.keyboardShortcut("n").disabled(covers.busy); Button("粘贴链接") { store.paste(); store.page = "新建下载" }.keyboardShortcut("v", modifiers: [.command, .shift]).disabled(store.busy || batch.isRunning || covers.busy); Button("选择保存位置…") { store.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(store.busy || batch.isRunning || covers.busy) } }
    }
}
