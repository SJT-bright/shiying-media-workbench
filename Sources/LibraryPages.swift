import SwiftUI
import AppKit

// MARK: - 拾影「下载记录」/「使用说明」（任务 B）
//
// 视觉全部走 QQStyle.swift 的契约公共组件；数据与动作只调用 Store 既有成员，
// 本页不新增下载语义。外层 ScrollView 由整合者（D）提供，这里只输出自然内容栈。

private enum LibraryStyle {
    static let cool = LinearGradient(colors: [QQTheme.cyan, QQTheme.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let steel = LinearGradient(colors: [QQTheme.slate, QQTheme.slate.opacity(0.70)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let sky = LinearGradient(colors: [QQTheme.blue, QQTheme.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func color(for status: String) -> Color {
        switch status {
        case "完成": return QQTheme.green
        case "已取消": return QQTheme.slate
        default: return QQTheme.orange
        }
    }

    static func gradient(for status: String) -> LinearGradient {
        switch status {
        case "完成": return QQTheme.success
        case "已取消": return steel
        default: return QQTheme.warm
        }
    }

    static func symbol(for status: String) -> String {
        switch status {
        case "完成": return "play.rectangle.fill"
        case "已取消": return "slash.circle.fill"
        default: return "xmark.seal.fill"
        }
    }

    static func badgeSymbol(for status: String) -> String {
        switch status {
        case "完成": return "checkmark.circle.fill"
        case "已取消": return "slash.circle"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

private struct HistoryDay: Identifiable {
    let day: Date
    var records: [Record]
    var id: Date { day }
}

private struct LibraryStat: View {
    let symbol: String
    let value: String
    let unit: String
    let caption: String
    let gradient: LinearGradient

    var body: some View {
        HStack(spacing: 10) {
            QQIconTile(symbol: symbol, size: 32, gradient: gradient)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.primary)
                    if !unit.isEmpty { Text(unit).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 下载记录

struct ShiyingHistoryView: View {
    @EnvironmentObject var metrics: WorkStatisticsStore
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var batch: BatchStore
    @Environment(\.colorScheme) private var scheme
    @State private var shown = 60
    @State private var source: MediaSource? = nil
    private let columns = [GridItem(.adaptive(minimum: 222, maximum: 300), spacing: 12, alignment: .top)]

    private var statisticsRequests: [WorkStatisticsRequest] {
        completed.compactMap { WorkStatisticsRepository.request(link: $0.link, videoID: $0.videoID) }
            + collected.compactMap { WorkStatisticsRepository.request(link: $0.link, videoID: $0.videoID, homepage: $0.creatorSourceURL) }
    }
    private var statisticsLabels: [String: String] {
        var result: [String: String] = [:]
        for record in completed {
            if let id = WorkStatisticsRepository.id(link: record.link, videoID: record.videoID) { result[id] = record.title }
        }
        for item in collected {
            if let id = WorkStatisticsRepository.id(link: item.link, videoID: item.videoID) { result[id] = item.title }
        }
        return result
    }
    private var statisticsSkipped: Int { completed.count + collected.count - statisticsRequests.count }
    private var sourceCounts: [MediaSource: Int] {
        var result: [MediaSource: Int] = [:]
        for record in store.filtered { result[.from(link: record.link), default: 0] += 1 }
        if store.filter == "全部" || store.filter == "完成" {
            for item in batch.items where item.status == .completed && (store.search.isEmpty || (item.title + " " + item.author).localizedCaseInsensitiveContains(store.search)) {
                result[.from(link: item.link), default: 0] += 1
            }
        }
        return result
    }
    private func matchesSource(_ link: String) -> Bool { source == nil || source == .from(link: link) }
    private var collected: [BatchItem] {
        guard store.filter == "全部" || store.filter == "完成" else { return [] }
        return batch.items.filter {
            $0.status == .completed && matchesSource($0.link) && (store.search.isEmpty
                || ($0.title + " " + $0.author).localizedCaseInsensitiveContains(store.search))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private var completed: [Record] { store.filtered.filter { $0.status == "完成" && matchesSource($0.link) } }
    private var coverCandidates: [ShiyingCoverCandidate] {
        store.records.filter { $0.status == "完成" }.map { ShiyingCoverCandidate(link: $0.link, videoID: $0.videoID, path: $0.path, imagePaths: $0.imagePaths) }
            + batch.items.filter { $0.status == .completed }.map { ShiyingCoverCandidate(link: $0.link, videoID: $0.videoID, path: $0.path, imagePaths: $0.imagePaths) }
    }
    private var unfinished: [Record] { store.filtered.filter { $0.status != "完成" && matchesSource($0.link) } }
    private var visibleCount: Int { completed.count + collected.count + unfinished.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let issue = store.historyIssue {
                QQDepthSurface(radius: 18, padding: 16, accent: QQTheme.orange) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("下载记录需要处理", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .semibold))
                        Text(issue).font(.system(size: 12)).textSelection(.enabled)
                        Button { store.openHistoryFolder() } label: { Label("打开记录文件夹", systemImage: "folder") }
                            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.orange))
                    }
                }
            }
            toolbar
            ShiyingSourceFilter(selection: $source, counts: sourceCounts)
            WorkStatisticsControls(requests: statisticsRequests, skipped: statisticsSkipped, labels: statisticsLabels)
            if visibleCount == 0 {
                QQDepthSurface(radius: 22, padding: 28, accent: QQTheme.blue) {
                    VStack(spacing: 14) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 40, weight: .light)).foregroundStyle(QQTheme.blue)
                        Text(store.search.isEmpty ? "保存的作品会出现在这里" : "没有匹配的作品")
                            .font(.system(size: 16, weight: .medium))
                        Button { store.page = "新建下载" } label: { Label("新建下载", systemImage: "plus") }
                            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue))
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            } else {
                ForEach(MediaSource.allCases) { group in
                    let singles = completed.filter { MediaSource.from(link: $0.link) == group }
                    let collectedItems = collected.filter { MediaSource.from(link: $0.link) == group }
                    if !singles.isEmpty || !collectedItems.isEmpty {
                        ShiyingSourceHeading(source: group, count: singles.count + collectedItems.count)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(Array(completed.prefix(shown)).filter { MediaSource.from(link: $0.link) == group }) { record in
                                ShiyingVideoTile(title: record.title, author: record.author, description: record.description,
                                    path: record.path, imagePaths: record.imagePaths, coverPath: ShiyingCoverResolver.path(link: record.link, videoID: record.videoID, preferred: record.imagePaths?.first ?? record.path, candidates: coverCandidates), source: group, statistics: metrics.entry(link: record.link, videoID: record.videoID), statisticsChange: metrics.change(link: record.link, videoID: record.videoID), play: { store.play(record) }, reveal: { store.reveal(record) })
                                    .contextMenu { Button("移除下载记录") { store.remove(record) } }
                            }
                            ForEach(Array(collected.prefix(max(0, shown - completed.count))).filter { MediaSource.from(link: $0.link) == group }) { item in
                                ShiyingVideoTile(title: item.title, author: item.author, description: item.description,
                                    path: item.path, imagePaths: item.imagePaths, coverPath: ShiyingCoverResolver.path(link: item.link, videoID: item.videoID, preferred: item.imagePaths?.first ?? item.path, candidates: coverCandidates), source: group, statistics: metrics.entry(link: item.link, videoID: item.videoID), historicalLikes: item.creatorDiggCount, historicalCollects: item.creatorCollectCount, statisticsChange: metrics.change(link: item.link, videoID: item.videoID), play: { batch.play(item) }, reveal: { batch.reveal(item) })
                            }
                        }
                    }
                }
                if shown < completed.count + collected.count {
                    Button { shown += 60 } label: { Text("显示更多") }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue))
                }
                ForEach(unfinished) { record in
                    QQDepthSurface(radius: 16, padding: 14, accent: QQTheme.orange) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(MediaSource.from(link: record.link).title, systemImage: MediaSource.from(link: record.link).symbol).font(.system(size: 10)).foregroundStyle(QQTheme.cyan)
                                Text(record.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                Text(record.error ?? record.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button { store.retry(record) } label: { Label("重试", systemImage: "arrow.clockwise") }
                                .buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue)).disabled(store.busy || batch.isRunning)
                            Button { store.remove(record) } label: { Image(systemName: "xmark") }
                                .buttonStyle(QQGhostPressStyle()).help("移除记录，保留文件")
                        }
                    }
                }
            }
        }
        .onChange(of: store.search) { _, _ in shown = 60 }
        .onChange(of: store.filter) { _, _ in shown = 60 }
        .onChange(of: source) { _, _ in shown = 60 }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索作品名称或博主", text: $store.search).textFieldStyle(.plain)
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
            }
            .padding(12).shiyingGlass(radius: 13, inset: true)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .qqControlMotion(tint: QQTheme.blue, radius: 13)
            Text("\(visibleCount) 个作品").font(.system(size: 11)).foregroundStyle(.secondary)
            ShiyingGlassMenu(title: "筛选", selection: $store.filter,
                values: ["全部", "完成", "失败", "已取消"], display: { $0 }).frame(width: 112)
        }
    }
}

// MARK: - 使用说明

struct ShiyingHelpView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            steps
            creatorNote
            topics
            local
            opensource
        }
    }

    private var steps: some View {
        QQDepthSurface(radius: 20, padding: 16, accent: QQTheme.cyan) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    QQIconTile(symbol: "wand.and.stars", size: 36, gradient: QQTheme.brand)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("三步保存作品").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        Text("粘贴链接，选择画质，保存到你的 Mac。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        store.page = "新建下载"
                    } label: {
                        Label("去新建下载", systemImage: "arrow.right")
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                }
                instruction("01", "粘贴链接", "在抖音中复制视频或图文分享链接，整段分享文案也可以直接粘贴。", QQTheme.blue)
                instruction("02", "选画质与文件夹", "视频可选480P、720P或最高画质；图文保留图片尺寸和格式。", QQTheme.violet)
                instruction("03", "下载并收藏", "完成后直接播放视频或在App里查看图片。下载记录保存在本机。", QQTheme.teal)
            }
        }
    }

    private var creatorNote: some View {
        QQDepthSurface(radius: 20, padding: 16, accent: QQTheme.mint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    QQIconTile(symbol: "film.stack", size: 30, gradient: QQTheme.brand)
                    Text("博主采集").font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    Button {
                        store.page = "博主采集"
                    } label: {
                        Label("去博主采集", systemImage: "arrow.right")
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                }
                Text("主页 → 筛选 → 下载。粘贴公开主页或主页分享短链，按日期、点赞和收藏挑出视频，再放进已有的收集文件夹。只采到一部分时，页面会写「仅采到部分」。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func instruction(_ number: String, _ title: String, _ description: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(tint).frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .shiyingGlass(radius: 14, inset: true)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(QQPalette(scheme).hairline, lineWidth: 0.9))
    }

    private var topics: some View {
        HStack(alignment: .top, spacing: 18) {
            topic(symbol: "slider.horizontal.3", title: "关于画质", tint: QQTheme.violet,
                  gradient: QQTheme.brand,
                  body: "480P / 720P 以画面的短边为准，保持原始横竖比例。没有对应视频源时会自动转换；原视频分辨率更低时保留原尺寸，避免放大。最高画质指平台当前提供的最高可用视频源。")
            topic(symbol: "link", title: "关于链接", tint: QQTheme.cyan,
                  gradient: LibraryStyle.sky,
                  body: "新建下载支持抖音单视频与图文链接，也支持B站、视频号和小红书视频。博主采集接受公开主页或主页分享短链，筛完再进入现有收集文件夹。图文保存为按顺序编号的图片文件夹；博主主页筛选仍沿用视频选择，直播不作为下载素材。取消任务会清理本次临时文件；重名文件会另存，不覆盖你的收藏。")
        }
    }

    private func topic(symbol: String, title: String, tint: Color, gradient: LinearGradient, body text: String) -> some View {
        QQDepthSurface(radius: 22, padding: 20, accent: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    QQIconTile(symbol: symbol, size: 30, gradient: gradient)
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var local: some View {
        QQDepthSurface(radius: 22, padding: 20, accent: QQTheme.green) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    QQIconTile(symbol: "lock.shield.fill", size: 30, gradient: QQTheme.success)
                    Text("关于文件与记录").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    QQPill(text: "保存在本机", tint: QQTheme.green, symbol: "checkmark.circle.fill")
                    QQPill(text: "登录保持到清除为止", tint: QQTheme.slate, symbol: "person.crop.circle.badge.checkmark")
                    QQPill(text: "同名文件自动另存", tint: QQTheme.blue, symbol: "doc.on.doc")
                    Spacer(minLength: 0)
                }
                Text("视频与下载记录都存放在你自己的电脑上；只移除记录不会删除已下载的视频，取消的任务会清理本次临时文件。博主登录保存在本机，退出拾影后仍然有效，直到清除登录状态或抖音要求重新登录。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            }
        }
    }

    private var opensource: some View {
        QQDepthSurface(radius: 22, padding: 20, accent: QQTheme.amber) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    QQIconTile(symbol: "shippingbox.fill", size: 30, gradient: QQTheme.warm)
                    Text("开源组件").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                Link("Douyin_TikTok_Download_API · Evil0ctal",
                     destination: URL(string: "https://github.com/Evil0ctal/Douyin_TikTok_Download_API")!)
                    .font(.system(size: 12))
                    .qqControlMotion(tint: QQTheme.amber)
                Text("视频处理：FFmpeg。组件版本与许可随 App 一起附带。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("查看组件许可", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.warm, tint: QQTheme.orange))
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
