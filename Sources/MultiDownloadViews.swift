import SwiftUI
import AppKit

/// 新建下载的多链接结果：身份与顺序来自输入，每一条只更新自己的状态。
struct ShiyingMultiDownloadList: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.linkItems.isEmpty {
                HStack(spacing: 8) {
                    Label("作品预览", systemImage: "rectangle.stack")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("\(store.linkItems.count) 条 · 按输入顺序")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 3)
                ForEach(store.linkItems) { item in
                    ShiyingMultiLinkCard(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShiyingMultiLinkCard: View {
    @ObservedObject var item: SingleLinkItem
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var batch: BatchStore
    @Environment(\.colorScheme) private var scheme
    private var palette: QQPalette { QQPalette(scheme) }

    private var tint: Color {
        if item.error != nil { return QQTheme.rose }
        if item.isCompleted { return QQTheme.teal }
        if item.canConfirm { return QQTheme.amber }
        return QQTheme.cyan
    }

    private var stateSymbol: String {
        if item.error != nil { return "exclamationmark.triangle" }
        if item.isCompleted { return "checkmark.circle" }
        if item.canConfirm { return "photo.on.rectangle" }
        if item.busy { return "arrow.down.circle" }
        return "clock"
    }

    private var placeholderTitle: String {
        if item.busy { return "正在读取作品信息…" }
        if item.error != nil { return "这条作品暂未解析成功" }
        if item.status == "已取消" { return "这条作品已取消" }
        return "等待解析作品信息"
    }

    var body: some View {
        QQDepthSurface(padding: 16, accent: tint, hoverable: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    QQPill(text: "第 \(item.position) 条", tint: QQTheme.slate, variant: .neutral, compact: true)
                    Text(item.link).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(item.link)
                    Spacer(minLength: 0)
                    QQPill(text: item.status, tint: tint, symbol: stateSymbol, compact: true)
                }
                if let video = item.video {
                    if store.captureCover || video.isAlbum {
                        photoPreview(video)
                    } else {
                        videoPreview(video)
                    }
                } else {
                    HStack(spacing: 14) {
                        QQIconTile(symbol: "film", size: 44, gradient: QQTheme.cool)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(placeholderTitle)
                                .font(.system(size: 13, weight: .semibold))
                            Text("标题、作者与封面将在解析后显示")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 5)
                }
                if item.busy {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(item.detail.isEmpty ? item.status : item.detail)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text("\(Int(max(0, min(1, item.overall)) * 100))%")
                                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(tint)
                        }
                        ProgressView(value: max(0, min(1, item.overall))).tint(tint)
                    }
                } else if !item.detail.isEmpty && item.error == nil && !item.isCompleted {
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error = item.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(QQTheme.rose)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let message = item.photoMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !item.completedResults.isEmpty {
                    ForEach(item.completedResults) { record in
                        savedRecord(record)
                    }
                }
                actions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("第 \(item.position) 条作品，\(item.status)")
    }

    private func videoPreview(_ video: Video) -> some View {
        HStack(alignment: .center, spacing: 14) {
            AsyncImage(url: video.cover.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        QQTheme.cyan.opacity(scheme == .dark ? 0.25 : 0.10)
                        Image(systemName: "film").font(.system(size: 26)).foregroundStyle(QQTheme.cyan)
                    }
                }
            }
            .frame(width: 124, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hairline, lineWidth: 0.8))
            VStack(alignment: .leading, spacing: 8) {
                ShiyingMultiLinkTitle(text: video.title)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(video.author).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }.frame(height: 16)
                ViewThatFits(in: .horizontal) {
                    metadata(video)
                    VStack(alignment: .leading, spacing: 6) {
                        QQPill(text: video.time, tint: QQTheme.cyan, symbol: "clock", compact: true)
                        QQPill(text: video.dimensions, tint: QQTheme.blue, symbol: "rectangle.expand.vertical", compact: true)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadata(_ video: Video) -> some View {
        HStack(spacing: 7) {
            QQPill(text: video.time, tint: QQTheme.cyan, symbol: "clock", compact: true)
            QQPill(text: video.dimensions, tint: QQTheme.blue, symbol: "rectangle.expand.vertical", compact: true)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func photoPreview(_ video: Video) -> some View {
        let draft = item.photoDraft ?? item.completedResults.last(where: { $0.isAlbum })
        let cover = store.captureCover
        return ShiyingPhotoPreview(title: video.title, author: video.author,
            images: cover ? [PhotoPreview(url: video.cover ?? "", width: draft?.width, height: draft?.height)] : video.images ?? [],
            paths: item.photoPaths,
            onCopy: { item.copyPhoto($0) },
            onView: { index in
                if let record = item.photoDraft ?? item.completedResults.last(where: { $0.isAlbum }) ?? item.result, record.isAlbum {
                    item.play(record, initialIndex: index)
                }
            }, kindTitle: cover ? "封面" : "图文", isTemporary: item.photoDraft != nil || !item.hasSavedResult)
            .help(video.title)
    }

    private func savedRecord(_ record: Record) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                savedDescription(record)
                Spacer(minLength: 6)
                savedActions(record)
            }
            VStack(alignment: .leading, spacing: 8) {
                savedDescription(record)
                savedActions(record)
            }
        }
        .padding(10).shiyingGlass(radius: 12, tint: QQTheme.teal.opacity(0.06), inset: true)
    }

    private func savedDescription(_ record: Record) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(record.isCover ? "封面已保存" : record.isAlbum ? "图文已保存" : "视频已保存", systemImage: "checkmark.circle")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(QQTheme.teal)
            Text(record.isAlbum ? "\(record.imagePaths?.count ?? 0) 张图片 · \(sizeText(record.bytes))" : "\(record.width) × \(record.height) · \(sizeText(record.bytes))")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func savedActions(_ record: Record) -> some View {
        HStack(spacing: 6) {
            Button { item.play(record) } label: {
                Label(record.isAlbum ? "查看图片" : "播放", systemImage: record.isAlbum ? "photo.on.rectangle" : "play.fill")
            }.buttonStyle(QQSoftButtonStyle())
            Button { item.reveal(record) } label: {
                Label("显示文件", systemImage: "folder")
            }.buttonStyle(QQSoftButtonStyle())
        }.font(.system(size: 11, weight: .medium))
    }

    @ViewBuilder private var actions: some View {
        if item.busy || (store.busy && !item.isCompleted) {
            HStack {
                Spacer(minLength: 0)
                Button("取消这条") { store.cancelLinkItem(item.id) }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose)).disabled(store.cancelling || item.status == "已取消")
            }
        } else if !item.isCompleted {
            HStack(spacing: 8) {
                if item.canConfirm {
                    Text(item.photoDraft?.isCover == true ? "临时封面，确认后保存" : "临时图文，确认后保存")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if item.error != nil || item.status == "已取消" {
                    Button("重试这条") { store.retryLinkItem(item.id) }
                        .buttonStyle(QQSoftButtonStyle()).disabled(store.busy || batch.isRunning)
                } else if item.canConfirm {
                    Button("取消保存") { store.cancelLinkItem(item.id) }
                        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose)).disabled(store.busy || batch.isRunning)
                    Button(item.confirmationTitle) { store.confirmLinkItem(item.id) }
                        .buttonStyle(QQDepthButtonStyle()).disabled(store.busy || batch.isRunning)
                } else if item.video != nil {
                    Button("下载这条") { store.confirmLinkItem(item.id) }
                        .buttonStyle(QQDepthButtonStyle()).disabled(store.busy || batch.isRunning || !store.captureSelectionValid)
                }
            }
        }
    }
}

/// 与已有作品卡片相同：标题固定一行高，滚动可读完整分享标题。
private struct ShiyingMultiLinkTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden().accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                ScrollView(.vertical) {
                    Text(text).font(.system(size: 14, weight: .semibold)).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.clipped()
            }
            .help(text)
    }
}

/// 固定底栏沿用单条的操作区，逐条状态始终在上方的卡片里可见。
struct ShiyingMultiDownloadActions: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var batch: BatchStore

    private var waiting: Bool { store.linkItems.contains(where: \.canConfirm) }
    private var unfinished: Bool { store.linkItems.isEmpty || store.linkItems.contains { !$0.isCompleted } }

    var body: some View {
        HStack(spacing: 8) {
            if waiting {
                Button("取消未保存") { store.discardAllLinkItems() }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose)).disabled(batch.isRunning)
                Button(store.captureVideo && store.captureCover ? "确认全部并下载" : "确认全部保存") { store.confirmAllLinkItems() }
                    .buttonStyle(QQDepthButtonStyle()).disabled(batch.isRunning)
            } else if unfinished {
                Button { store.download() } label: {
                    Label(store.captureCover && !store.captureVideo ? "提取全部封面" : "下载全部", systemImage: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .semibold))
                }.buttonStyle(QQDepthButtonStyle())
                    .disabled(batch.isRunning || !store.captureSelectionValid || store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                QQPill(text: "全部已保存", tint: QQTheme.teal, symbol: "checkmark.circle", compact: true)
            }
        }
    }
}
