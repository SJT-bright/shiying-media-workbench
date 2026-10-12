import SwiftUI
import AppKit

/// 公众号链接和保存位置的紧凑条，替换文章页上的大输入板与保存位置卡。
///
/// 宽窗口里「链接」、输入框、「粘贴」「添加文章」「保存全部」在同一行。
/// 窄到放不下最小输入框时，输入框仍保持固定高度，按钮落到下一行并可横向滚动。
/// 多行链接在输入框内部上下滚动。保存位置单独一行：路径在行内横向滚动，
/// 「更改…」打开现有 `ShiyingFolderPicker`（浏览、新建、确认、取消都在选择器里）。
///
/// `collections` 与 `libraryRoot` 都传入时不读取环境。省略任一项时，该项从环境里的
/// `BatchStore` 读取（`collections`、`parentFolder`）。集成时去掉页面上原来的
/// `choosingFolder` sheet，避免和这里叠两个选择器。
struct ArticleCompactControls: View {
    @ObservedObject private var articles: ArticleStore
    private let givenCollections: [StudyCollection]?
    private let givenLibraryRoot: String?

    init(articles: ArticleStore, collections: [StudyCollection]? = nil, libraryRoot: String? = nil) {
        _articles = ObservedObject(wrappedValue: articles)
        givenCollections = collections
        givenLibraryRoot = libraryRoot
    }

    var body: some View {
        if let givenCollections, let givenLibraryRoot {
            ArticleCompactControlsBody(
                articles: articles,
                collections: givenCollections,
                libraryRoot: givenLibraryRoot
            )
        } else {
            ArticleCompactControlsBatchBridge(
                articles: articles,
                collections: givenCollections,
                libraryRoot: givenLibraryRoot
            )
        }
    }
}

private struct ArticleCompactControlsBatchBridge: View {
    @ObservedObject var articles: ArticleStore
    var collections: [StudyCollection]?
    var libraryRoot: String?
    @EnvironmentObject private var batch: BatchStore

    var body: some View {
        ArticleCompactControlsBody(
            articles: articles,
            collections: collections ?? batch.collections,
            libraryRoot: libraryRoot ?? batch.parentFolder
        )
    }
}

private enum ArticleCompactMetrics {
    static let editorHeight: CGFloat = 36
    static let minEditorWidth: CGFloat = 156
    static let spacing: CGFloat = 8
    static let rowGap: CGFloat = 6
}

private struct ArticleCompactBarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ArticleCompactControlsBody: View {
    @ObservedObject var articles: ArticleStore
    let collections: [StudyCollection]
    let libraryRoot: String
    @State private var barWidth: CGFloat = 0
    @State private var labelWidth: CGFloat = 72
    @State private var actionWidth: CGFloat = 320
    @State private var actionHeight: CGFloat = 36
    @State private var editorFocused = false

    private var linkRowFits: Bool {
        guard barWidth > 1 else { return true }
        let needed = labelWidth + actionWidth + ArticleCompactMetrics.minEditorWidth + ArticleCompactMetrics.spacing * 2
        return barWidth + 0.5 >= needed
    }

    private var linkBlockHeight: CGFloat {
        if linkRowFits { return max(ArticleCompactMetrics.editorHeight, actionHeight) }
        return ArticleCompactMetrics.editorHeight + ArticleCompactMetrics.rowGap + actionHeight
    }

    var body: some View {
        QQDepthSurface(radius: 16, padding: 10, accent: QQTheme.teal) {
            VStack(alignment: .leading, spacing: 8) {
                linkBlock
                saveRow
                statusBlock
            }
        }
        .sheet(isPresented: $articles.choosingFolder) {
            ShiyingFolderPicker(
                title: "选择公众号文章保存位置",
                initialPath: articles.folder,
                collections: collections,
                libraryRoot: libraryRoot,
                busy: articles.busy
            ) { path in
                do {
                    _ = try FolderBrowser.directory(path, writable: true)
                    articles.folder = path
                    articles.error = nil
                    return true
                } catch {
                    articles.error = error.localizedDescription
                    return false
                }
            }
        }
    }

    private var linkBlock: some View {
        Group {
            if linkRowFits {
                HStack(alignment: .center, spacing: ArticleCompactMetrics.spacing) {
                    linkLabel
                    linkEditor.frame(maxWidth: .infinity)
                    linkActions
                }
            } else {
                VStack(alignment: .leading, spacing: ArticleCompactMetrics.rowGap) {
                    HStack(alignment: .center, spacing: ArticleCompactMetrics.spacing) {
                        linkLabel
                        linkEditor.frame(maxWidth: .infinity)
                    }
                    .frame(height: ArticleCompactMetrics.editorHeight)
                    ScrollView(.horizontal, showsIndicators: false) {
                        linkActions
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .frame(height: actionHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: linkBlockHeight, maxHeight: linkBlockHeight, alignment: .top)
        .clipped()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ArticleCompactBarWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(ArticleCompactBarWidthKey.self) { width in
            guard abs(width - barWidth) > 0.5 else { return }
            barWidth = width
        }
    }

    private var linkLabel: some View {
        Label("链接", systemImage: "doc.text")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(QQTheme.teal)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("公众号文章链接")
            .help("粘贴一篇或多篇文章链接，每次最多200篇。保存 Markdown 正文、离线网页和原图，按公众号分文件夹。")
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width in
                guard width > 1, abs(width - labelWidth) > 0.5 else { return }
                labelWidth = width
            })
    }

    private var linkEditor: some View {
        ArticleCompactLinkEditor(text: $articles.text, isEnabled: !articles.busy, focused: $editorFocused)
            .frame(height: ArticleCompactMetrics.editorHeight)
            .clipped()
            .overlay(alignment: .topLeading) {
                if articles.text.isEmpty {
                    Text("每行一条，最多200篇")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 4)
                        .padding(.leading, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .shiyingGlass(radius: 10, inset: true)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(editorFocused && !articles.busy ? QQTheme.blue.opacity(0.65) : .clear, lineWidth: 1.25)
                    .allowsHitTesting(false)
            }
            .opacity(articles.busy ? 0.55 : 1)
    }

    private var linkActions: some View {
        HStack(spacing: ArticleCompactMetrics.spacing) {
            Button { articles.paste() } label: {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }
            .font(.system(size: 12))
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.teal))
            .disabled(articles.busy)

            Button("添加文章") { articles.addLinks() }
                .font(.system(size: 12))
                .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                .disabled(articles.busy || articles.text.isEmpty)

            if articles.busy {
                Button("停止采集") { articles.cancel() }
                    .font(.system(size: 12))
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.orange))
            } else {
                Button { articles.saveAll() } label: {
                    Label("保存全部", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(QQDepthButtonStyle(compact: true))
                .disabled(articles.records.isEmpty && articles.text.isEmpty)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { size in
            guard size.width > 1 else { return }
            if abs(size.width - actionWidth) > 0.5 { actionWidth = size.width }
            if abs(size.height - actionHeight) > 0.5 { actionHeight = size.height }
        })
    }

    private var saveRow: some View {
        HStack(alignment: .center, spacing: ArticleCompactMetrics.spacing) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(QQTheme.orange)
                .accessibilityHidden(true)
            Text("保存位置")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .help("保存为：公众号 / 公众号名称 / 文章标题")
            ArticleCompactScrollingPath(text: shortFolder(articles.folder), fullPath: articles.folder)
            Button { articles.choosingFolder = true } label: {
                Label("更改…", systemImage: "folder")
            }
            .font(.system(size: 12))
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.orange))
            .disabled(articles.busy)
            .fixedSize()
            .accessibilityLabel("更改文章保存位置")
            .help("在拾影里浏览本机目录、新建文件夹。确认后更换位置，取消则保持原位置。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var statusBlock: some View {
        if articles.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if !articles.detail.isEmpty {
                    Text(articles.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(QQTheme.cyan)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(articles.detail)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(articles.detail.isEmpty ? "正在采集" : articles.detail)
        }
        if let notice = articles.notice {
            Text(notice)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .help(notice)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = articles.error {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(QQTheme.orange)
                .textSelection(.enabled)
                .lineLimit(2)
                .help(error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortFolder(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// 路径只占一行，短路径靠左，长路径在这一行里横向滚动。
private struct ArticleCompactScrollingPath: View {
    let text: String
    let fullPath: String

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("文章保存位置")
        .accessibilityValue(fullPath)
        .help(fullPath)
    }
}

/// 固定高度的纯文本框。SwiftUI `TextEditor` 的 AppKit 固有高度会把行撑回大输入板，
/// 所以这里锁住 `sizeThatFits` 的高度，多出来的行只在框内滚动。
private struct ArticleCompactLinkEditor: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focused: $focused)
    }

    func makeNSView(context: Context) -> ArticleCompactLinkScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isRulerVisible = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.focusRingType = .none
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainerInset = NSSize(width: 4, height: 2)
        textView.delegate = context.coordinator
        textView.string = text
        textView.setAccessibilityLabel("公众号文章链接输入")
        textView.setAccessibilityHelp("可粘贴多行链接，内容在框内上下滚动。一次最多200篇。")
        applyEnabled(isEnabled, to: textView)

        let scroll = ArticleCompactLinkScrollView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.focusRingType = .none
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.contentView.drawsBackground = false
        scroll.documentView = textView
        scroll.onLayout = { [weak scroll] in
            guard let scroll else { return }
            Self.syncTextWidth(scroll)
        }
        Self.syncTextWidth(scroll)
        return scroll
    }

    func updateNSView(_ scroll: ArticleCompactLinkScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focused = $focused
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text, textView.markedRange().location == NSNotFound {
            context.coordinator.updating = true
            textView.string = text
            context.coordinator.updating = false
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        applyEnabled(isEnabled, to: textView)
        if !isEnabled, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
        Self.syncTextWidth(scroll)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ArticleCompactLinkScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? ArticleCompactMetrics.minEditorWidth, height: ArticleCompactMetrics.editorHeight)
    }

    private func applyEnabled(_ enabled: Bool, to textView: NSTextView) {
        textView.isEditable = enabled
        textView.isSelectable = enabled
        let color: NSColor = enabled ? .labelColor : .disabledControlTextColor
        textView.textColor = color
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: color
        ]
    }

    private static func syncTextWidth(_ scroll: NSScrollView) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let width = max(scroll.contentSize.width, 1)
        if abs(textView.frame.width - width) > 0.5 {
            var frame = textView.frame
            frame.size.width = width
            textView.frame = frame
        }
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focused: Binding<Bool>
        var updating = false

        init(text: Binding<String>, focused: Binding<Bool>) {
            self.text = text
            self.focused = focused
        }

        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            let next = view.string
            if text.wrappedValue != next { text.wrappedValue = next }
        }

        func textDidBeginEditing(_ notification: Notification) { focused.wrappedValue = true }
        func textDidEndEditing(_ notification: Notification) { focused.wrappedValue = false }
    }
}

private final class ArticleCompactLinkScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    private var inLayout = false

    override func layout() {
        super.layout()
        guard !inLayout else { return }
        inLayout = true
        onLayout?()
        inLayout = false
    }
}
