import SwiftUI

// 批量收集与收集文件夹。批量收集页自己占满剩余高度：模式入口固定在上方。
// 多链接内容在页内滚动；博主主页交给 ShiyingCreatorView，结果列表单独滚。
// 只调用 BatchStore / CreatorStore 公开接口，不创建 store，不自己写磁盘或进程。
// 配套音轨由 B 从已保存视频本地导出。本页不提供转录或自动分析。

private enum BatchPageLimit {
    static let pageSize = 100
}

private struct BatchPagedStack<Row: View>: View {
    let items: [BatchItem]
    let resetKey: String
    @ViewBuilder var row: (BatchItem) -> Row
    @State private var shown = BatchPageLimit.pageSize

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(items.prefix(shown)) { item in
                row(item)
            }
        }
        .onChange(of: resetKey) { _, _ in shown = BatchPageLimit.pageSize }
        if shown < items.count {
            Button {
                shown = min(items.count, shown + BatchPageLimit.pageSize)
            } label: {
                Label("显示更多（\(shown)/\(items.count)）", systemImage: "ellipsis.circle")
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
        }
    }
}

private enum BatchIntake: String, CaseIterable, Identifiable {
    case links = "多链接导入"
    case home = "博主主页"
    var id: String { rawValue }
}

struct ShiyingBatchView: View {
    @EnvironmentObject var metrics: WorkStatisticsStore
    @EnvironmentObject var batch: BatchStore
    @Environment(\.colorScheme) private var scheme
    @State private var intake = BatchIntake.links
    @State private var source: MediaSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            intakeSwitcher
            QQPageReveal(pageID: intake.rawValue) {
                if intake == .links {
                    messages
                    ScrollView {
                        linksBody
                            .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ShiyingCreatorView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var intakeSwitcher: some View {
        HStack(spacing: 8) {
            intakeButton(.links, symbol: "link")
            intakeButton(.home, symbol: "person.crop.rectangle")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("收集方式")
    }

    @ViewBuilder
    private func intakeButton(_ mode: BatchIntake, symbol: String) -> some View {
        let selected = intake == mode
        let button = Button {
            intake = mode
        } label: {
            Label(mode.rawValue, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
        if selected {
            button.buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.mint, compact: true))
        } else {
            button.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
        }
    }

    private var linksBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            inputCard
            previewCard
            qualityCard
            folderCard
            queueCard
            if queueItems.isEmpty {
                queueEmpty
            } else {
                ShiyingSourceFilter(selection: $source, counts: Dictionary(grouping: queueItems, by: { MediaSource.from(link: $0.link) }).mapValues(\.count))
                BatchPagedStack(items: visibleItems.filter { $0.status != .completed }, resetKey: queueKey) { item in
                    queueRow(item)
                }
                ForEach(MediaSource.allCases) { platform in
                    let completed = visibleItems.filter { $0.status == .completed && MediaSource.from(link: $0.link) == platform }
                    if !completed.isEmpty {
                        ShiyingSourceHeading(source: platform, count: completed.count)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 222, maximum: 300), spacing: 12, alignment: .top)], spacing: 14) {
                            ForEach(completed) { item in
                                ShiyingVideoTile(title: item.title, author: item.author, description: item.description,
                                    path: item.path, imagePaths: item.imagePaths, coverPath: ShiyingCoverResolver.path(link: item.link, videoID: item.videoID, preferred: item.imagePaths?.first ?? item.path, candidates: queueItems.map { ShiyingCoverCandidate(link: $0.link, videoID: $0.videoID, path: $0.path, imagePaths: $0.imagePaths) }), source: platform, statistics: metrics.entry(link: item.link, videoID: item.videoID), historicalLikes: item.creatorDiggCount, historicalCollects: item.creatorCollectCount, statisticsChange: metrics.change(link: item.link, videoID: item.videoID), play: { batch.play(item) }, reveal: { batch.reveal(item) })
                            }
                        }
                    }
                }
            }
        }
    }

    private var queueItems: [BatchItem] {
        guard let id = batch.selectedCollectionID else { return [] }
        return batch.items.filter { $0.collectionID == id }
    }

    private var visibleItems: [BatchItem] { queueItems.filter { source == nil || MediaSource.from(link: $0.link) == source } }
    private var queueKey: String { (batch.selectedCollectionID?.uuidString ?? "none") + (source?.rawValue ?? "all") }

    private var header: some View {
        QQDepthSurface(radius: 20, padding: 16, accent: QQTheme.cyan) {
            HStack(alignment: .top, spacing: 12) {
                QQIconTile(symbol: "square.stack.3d.down.right.fill", size: 36, gradient: QQTheme.brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text("多链接导入").font(.system(size: 16, weight: .semibold))
                    Text("一次粘贴多条链接，或导入 UTF-8 文本。链接进入当前收集文件夹，按顺序逐条下载。勾选后，视频保存成功再在本机导出同名 M4A。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        if batch.error?.isEmpty == false || batch.notice?.isEmpty == false {
            VStack(alignment: .leading, spacing: 8) {
                if let error = batch.error, !error.isEmpty {
                    errorBanner(error)
                }
                if let notice = batch.notice, !notice.isEmpty {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var inputCard: some View {
        QQDepthSurface(radius: 22, padding: 18, accent: QQTheme.blue) {
            VStack(alignment: .leading, spacing: 12) {
                Text("链接").font(.system(size: 14, weight: .semibold))
                Text("txt 或 csv 都按纯文本提取链接，不会按表格列解读。单次文本最大 5 MiB、5000 条，超出会整次拒绝。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $batch.inputText)
                    .font(.system(size: 13))
                    .frame(minHeight: 140, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .shiyingGlass(radius: 12, inset: true)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .qqControlMotion(tint: QQTheme.cyan)
                HStack(spacing: 10) {
                    Button { batch.paste() } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan))
                    Button { batch.importTextFile() } label: {
                        Label("导入文本文件", systemImage: "doc.text")
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var previewCard: some View {
        QQDepthSurface(radius: 20, padding: 16, accent: QQTheme.teal) {
            VStack(alignment: .leading, spacing: 10) {
                Text("预览").font(.system(size: 14, weight: .semibold))
                if batch.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("粘贴或导入后，这里显示可加入条数、重复条数和无效行。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let preview = batch.preview {
                    HStack(spacing: 8) {
                        QQPill(text: "可加入 \(preview.links.count)", tint: QQTheme.green, symbol: "link")
                        QQPill(text: "重复 \(preview.duplicateCount)", tint: QQTheme.amber, symbol: "arrow.triangle.merge")
                        QQPill(text: "无效行 \(preview.invalidCount)", tint: QQTheme.slate, symbol: "minus.circle")
                    }
                    if preview.links.isEmpty {
                        Text("这些链接已全部在当前收集文件夹里，没有新的可加入。")
                            .font(.system(size: 12))
                            .foregroundStyle(QQTheme.orange)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("重复按这次文本和当前收集文件夹里已有链接去重，顺序保留。无效行只作提示，不会丢掉同一行里其他合法链接。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(readOnlyPreviewError)
                        .font(.system(size: 12))
                        .foregroundStyle(QQTheme.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 加入按钮在 canImport 为假时已经禁用，解析失败要在这里直接可见。只读调用，不写 Store，不入队。
    private var readOnlyPreviewError: String {
        let existing = Set(batch.items.filter { $0.collectionID == batch.selectedCollectionID }.map(\.link))
        do {
            _ = try BatchLinkParser.preview(batch.inputText, existing: existing)
            return "这段文本现在形成不了预览。"
        } catch {
            return error.localizedDescription
        }
    }

    private var folderCard: some View {
        QQDepthSurface(radius: 22, padding: 18, accent: QQTheme.violet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("收集文件夹").font(.system(size: 14, weight: .semibold))
                if batch.collections.isEmpty {
                    Text("还没有收集文件夹。填写名称后会在父目录下新建真实子目录，不会覆盖已有文件。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ShiyingGlassMenu(title: "已有文件夹", selection: collectionSelection,
                        values: batch.collections.map(\.id), display: { id in
                            batch.collections.first { $0.id == id }.map { CollectionOrganization.title(of: $0, in: batch.collections) } ?? ""
                        })
                        .frame(maxWidth: 360, alignment: .leading)
                }
                if let collection = batch.selectedCollection {
                    pathLine(collection.path)
                }
                TextField("新文件夹名称", text: $batch.newCollectionName)
                    .textFieldStyle(ShiyingGlassFieldStyle())
                    .qqControlMotion(tint: QQTheme.cyan)
                pathLine(batch.parentFolder)
                HStack(spacing: 10) {
                    Button { batch.chooseParentFolder() } label: {
                        Label("选择父目录", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.violet))
                    Button { batch.createCollection() } label: {
                        Label("创建文件夹", systemImage: "plus.rectangle.on.folder")
                    }
                    .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan))
                    .disabled(batch.newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || batch.isRunning)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var collectionSelection: Binding<UUID> {
        Binding(
            get: { batch.selectedCollectionID ?? batch.collections.first?.id ?? UUID() },
            set: { batch.selectCollection($0) }
        )
    }

    private var qualityCard: some View {
        QQDepthSurface(radius: 22, padding: 18, accent: QQTheme.cyan) {
            VStack(alignment: .leading, spacing: 12) {
                Text("画质与音轨").font(.system(size: 14, weight: .semibold))
                Text("画质和音轨开关在加入队列时记在每一条上。之后再改，只影响下一次加入的链接。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(Quality.allCases) { option in
                        qualityChoice(option)
                    }
                    Spacer(minLength: 0)
                }
                Toggle(isOn: $batch.includeAudio) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("同时导出配套音轨（M4A）").font(.system(size: 13, weight: .semibold))
                        Text("默认开启。视频保存后，从该视频在本机导出同名主体的 M4A，不重新下载。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .qqControlMotion(tint: QQTheme.cyan)
            }
        }
    }

    private var queueCard: some View {
        QQDepthSurface(radius: 22, padding: 18, accent: QQTheme.green) {
            VStack(alignment: .leading, spacing: 12) {
                Text("队列").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    QQPill(text: "全部待处理 \(batch.pendingCount)", tint: QQTheme.blue, symbol: "clock")
                    QQPill(text: "全部已完成 \(batch.completedCount)", tint: QQTheme.green, symbol: "checkmark.circle")
                    QQPill(text: "全部失败 \(batch.failedCount)", tint: QQTheme.orange, symbol: "exclamationmark.triangle")
                    QQPill(text: "全部已取消 \(batch.cancelledCount)", tint: QQTheme.slate, symbol: "slash.circle")
                }
                Text("下面只列出当前收集文件夹。开始、暂停、继续、取消当前，以及「重试失败与已取消」，都覆盖所有文件夹。已完成的视频保持不变。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: min(max(batch.progress, 0), 1))
                if !batch.detail.isEmpty {
                    Text(batch.detail)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(batch.isPaused ? "已暂停：当前这一条（含音轨步骤）结束后停止。点继续才会再开始。" : "一次只处理一条。单条失败不会停掉后面的任务。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { batch.enqueue() } label: {
                        Label("加入队列", systemImage: "text.badge.plus")
                    }
                    .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan, compact: true))
                    .disabled(!batch.canImport || batch.isRunning)
                    Button { batch.start() } label: {
                        Label("开始队列", systemImage: "play.fill")
                    }
                    .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.success, tint: QQTheme.green, compact: true))
                    .disabled(batch.isRunning || batch.pendingCount == 0)
                    Button { batch.pause() } label: {
                        Label("暂停", systemImage: "pause.fill")
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.orange))
                    .disabled(!batch.isRunning || batch.isPaused)
                    Button { batch.resume() } label: {
                        Label("继续", systemImage: "playpause.fill")
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.green))
                    .disabled(!batch.isPaused)
                }
                HStack(spacing: 8) {
                    Button { batch.cancelCurrent() } label: {
                        Label("取消当前并暂停", systemImage: "stop.fill")
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose))
                    .disabled(batch.runningItem == nil)
                    Button { batch.retryFailed() } label: {
                        Label("重试失败与已取消", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                    .disabled(batch.failedCount + batch.cancelledCount == 0 || batch.isRunning)
                    .help("重置所有收集文件夹里的失败和已取消任务。已完成的视频保持不变。")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func queueRow(_ item: BatchItem) -> some View {
        QQDepthSurface(radius: 18, padding: 14, accent: statusTint(for: item.status)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    QQPill(text: item.status.title, tint: statusTint(for: item.status), symbol: symbol(for: item.status))
                    QQPill(text: qualityTitle(item.qualityRaw), tint: QQTheme.violet, symbol: "slider.horizontal.3")
                    QQPill(text: audioBadge(item).text, tint: audioBadge(item).tint, symbol: audioBadge(item).symbol)
                    Spacer(minLength: 0)
                }
                Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                if !item.author.isEmpty {
                    Text(item.author).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(item.link)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let error = item.error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(QQTheme.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                audioDetail(item)
                if item.status == .failed || item.status == .cancelled {
                    Button { batch.retry(item.id) } label: {
                        Label("重试这一条", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                    .disabled(batch.isRunning)
                }
            }
        }
    }

    private var queueEmpty: some View {
        QQDepthSurface(radius: 22, padding: 22, accent: QQTheme.slate) {
            Text(batch.selectedCollection == nil ? "先创建或选择一个收集文件夹。" : "这个文件夹还没有排队的链接。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func qualityChoice(_ option: Quality) -> some View {
        if batch.quality == option {
            Button { batch.quality = option } label: {
                Label(option.title, systemImage: option.icon)
            }
            .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan, compact: true))
            .help(option.detail)
        } else {
            Button { batch.quality = option } label: {
                Label(option.title, systemImage: option.icon)
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
            .help(option.detail)
        }
    }

    private func pathLine(_ path: String) -> some View {
        Text(path)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}


private func statusTint(for status: BatchStatus) -> Color {
    switch status {
    case .completed: return QQTheme.green
    case .failed: return QQTheme.orange
    case .running: return QQTheme.blue
    case .cancelled: return QQTheme.slate
    case .pending: return QQTheme.cyan
    }
}

private func symbol(for status: BatchStatus) -> String {
    switch status {
    case .completed: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .running: return "arrow.down.circle.fill"
    case .cancelled: return "slash.circle"
    case .pending: return "clock"
    }
}

private func qualityTitle(_ raw: String) -> String {
    Quality(rawValue: raw)?.title ?? raw
}

private func audioBadge(_ item: BatchItem) -> (text: String, tint: Color, symbol: String) {
    if item.isAlbum { return ("图文 · \(item.imagePaths?.count ?? 0) 张", QQTheme.blue, "photo.on.rectangle") }
    if !item.wantsAudio {
        return ("未要求音轨", QQTheme.slate, "speaker.slash")
    }
    if item.audioPath?.isEmpty == false {
        return ("M4A 已配对", QQTheme.green, "waveform")
    }
    if item.status == .completed, item.audioError?.isEmpty == false {
        return ("音轨失败", QQTheme.rose, "waveform.badge.exclamationmark")
    }
    if item.status == .completed {
        return ("音轨未导出", QQTheme.amber, "waveform")
    }
    return ("视频完成后导出音轨", QQTheme.blue, "waveform")
}

@ViewBuilder
private func audioDetail(_ item: BatchItem) -> some View {
    if item.status == .completed, let audioError = item.audioError, !audioError.isEmpty {
        Text("视频已保存，音轨导出失败")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(QQTheme.rose)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        if audioError != "视频已保存，音轨导出失败" {
            Text(audioError)
                .font(.system(size: 12))
                .foregroundStyle(QQTheme.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func errorBanner(_ error: String) -> some View {
    QQDepthSurface(radius: 16, padding: 14, accent: QQTheme.orange) {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(QQTheme.orange)
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(QQTheme.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
