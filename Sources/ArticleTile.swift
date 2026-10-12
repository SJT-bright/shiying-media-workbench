import SwiftUI

/// 文章记录沿用紧凑视频卡片的尺度。左封面、右公众号与作者，不显示分辨率。
/// 封面视图只负责画面；整张封面和中央图标打开正文。重存、原文和移除可从右键菜单到达。
struct ShiyingArticleTile: View {
    let record: ArticleRecord
    let coverCacheRoot: URL
    let open: () -> Void
    let reveal: () -> Void
    let save: () -> Void
    let browser: () -> Void
    let remove: () -> Void

    private let coverSize = CGSize(width: 104, height: 58.5)

    private var accountName: String {
        let name = record.account.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "公众号" : name
    }

    private var authorName: String {
        record.author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsAuthor: Bool {
        !authorName.isEmpty && authorName != accountName
    }

    private var revealExists: Bool {
        guard let path = record.path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 已保存且文件仍在时，重存、原文、移除收进右键菜单。未保存或文件缺失时，这些动作留在卡片上。
    private var keepsActionsVisible: Bool {
        record.status != .saved || !record.available
    }

    private var saveLabel: String {
        record.status == .saved ? "重新保存" : "保存正文和图片"
    }

    private var checkedText: String {
        if !record.published.isEmpty { return record.published }
        let formatted = record.date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
        return (record.status == .saved ? "保存于 " : "添加于 ") + formatted
    }

    private var statusColor: Color {
        switch record.status {
        case .saved: return QQTheme.teal
        case .failed: return QQTheme.orange
        case .reading, .saving: return QQTheme.cyan
        case .pending: return .secondary
        }
    }

    var body: some View {
        QQDepthSurface(radius: 17, padding: 12, accent: record.status == .saved ? QQTheme.teal : QQTheme.blue) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    coverColumn
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(showsAuthor ? 1 : 2)
                            .help(accountName)
                        if showsAuthor {
                            Text(authorName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(authorName)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Label("公众号", systemImage: "doc.text.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(QQTheme.teal)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .shiyingGlass(radius: 8)
                        .accessibilityLabel("文章来源：公众号")
                    Spacer(minLength: 4)
                    Button(action: reveal) {
                        Image(systemName: "folder").font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                    .disabled(!revealExists)
                    .help(revealExists ? "在访达中显示" : (record.path == nil ? "尚未保存，没有本地文件" : "文件已移动或暂不可用"))
                    .accessibilityLabel("在访达中显示文章")
                }
                ArticleHorizontalTitle(text: record.title)
                ArticleTwoLineExcerpt(text: ArticleCardContent.storedExcerpt(record))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(checkedText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(record.status.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .font(.system(size: 9))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(checkedText + "，" + record.status.rawValue)
                if let issue = record.error, !issue.isEmpty {
                    issueLine(issue)
                }
                if record.status == .saved && !record.available {
                    Text("保存文件已移动或暂不可用，可重新保存。")
                        .font(.system(size: 11))
                        .foregroundStyle(QQTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if keepsActionsVisible {
                    ViewThatFits(in: .horizontal) {
                        actionRow(saveLabel)
                        actionRow(record.status == .saved ? "重新保存" : "保存")
                    }
                }
            }
        }
        .contextMenu {
            Button("打开正文", action: open)
            Button(saveLabel, action: save)
            Button("原文", action: browser)
            if revealExists {
                Button("在访达中显示", action: reveal)
            }
            Divider()
            Button("移除记录，保留文件", role: .destructive, action: remove)
        }
        .accessibilityHint(keepsActionsVisible ? "保存和原文在卡片内" : "右键可重新保存、打开原文或移除记录")
    }

    private var coverColumn: some View {
        Button(action: open) {
            ZStack {
                ArticleCoverView(record: record, cacheRoot: coverCacheRoot)
                    .frame(width: coverSize.width, height: coverSize.height)
                    .clipped()
                    .accessibilityHidden(true)
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.55), in: Circle())
                    .accessibilityHidden(true)
            }
            .frame(width: coverSize.width, height: coverSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开正文")
        .help("打开正文")
    }

    private func issueLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(QQTheme.orange)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func actionRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            Button(action: save) {
                Text(title)
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.teal))
            .help(saveLabel)
            .accessibilityLabel(saveLabel)
            Button("原文", action: browser)
                .buttonStyle(QQSoftButtonStyle())
                .help("在内置网页打开原文")
                .accessibilityLabel("在内置网页打开原文")
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(QQGhostPressStyle())
            .help("移除文章记录，保留已保存文件")
            .accessibilityLabel("移除文章记录，保留已保存文件")
        }
    }
}

/// 标题固定一行。超出卡片宽度时在水平 ScrollView 里往返滚动；内容不超出，或系统开启减弱动态效果时，不自动滚动。
private struct ArticleHorizontalTitle: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var started = Date()
    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var animates: Bool { !reduceMotion && !hovering && overflow > 2 }
    private var oneWayDuration: Double { max(3.2, Double(overflow) / 22) }

    var body: some View {
        Text("国")
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay { scroller }
            .clipped()
            .onPreferenceChange(ArticleTextWidthKey.self) { width in
                guard abs(width - textWidth) > 0.5 else { return }
                textWidth = width
            }
            .onPreferenceChange(ArticleSlotWidthKey.self) { width in
                guard abs(width - containerWidth) > 0.5 else { return }
                containerWidth = width
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("文章标题：" + text)
            .help(text)
    }

    private var scroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ArticleTextWidthKey.self, value: proxy.size.width)
                        }
                    }
                    .offset(x: animates ? -overflow * travel(at: context.date) : 0)
                    .transaction { $0.animation = nil }
            }
        }
        .scrollDisabled(overflow <= 2)
        .onHover { inside in hovering = inside; if !inside { started = Date() } }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ArticleSlotWidthKey.self, value: proxy.size.width)
            }
        }
    }

    /// 余弦往返：两端速度降为 0。相位来自标题本身，避免同一网格里的标题同步滑动。
    private func travel(at date: Date) -> CGFloat {
        let period = oneWayDuration * 2
        guard period > 0 else { return 0 }
        let elapsed = (max(0, date.timeIntervalSince(started) - 1))
            .truncatingRemainder(dividingBy: period)
        let angle = elapsed / period * 2 * Double.pi
        return CGFloat((1 - cos(angle)) / 2)
    }

}

/// 摘要使用 storedExcerpt（最多 50 个字符，超出已带 ...），高度固定为两行。
private struct ArticleTwoLineExcerpt: View {
    let text: String

    var body: some View {
        Text("国\n国")
            .font(.system(size: 12))
            .lineSpacing(3)
            .lineLimit(2)
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                Text(text)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("文章摘要：" + text)
    }
}

private struct ArticleTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ArticleSlotWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
