import SwiftUI
import WebKit

struct ShiyingArticleView: View {
    @EnvironmentObject var articles: ArticleStore
    @EnvironmentObject var batch: BatchStore
    @State private var search = ""
    private var shown: [ArticleRecord] { articles.records.filter { search.isEmpty || ($0.title + " " + $0.account).localizedCaseInsensitiveContains(search) }.sorted { $0.date > $1.date } }
    private let columns = [GridItem(.adaptive(minimum: 222, maximum: 300), spacing: 12, alignment: .top)]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ArticleCompactControls(articles: articles, collections: batch.collections, libraryRoot: batch.parentFolder)
            HStack(spacing: 10) {
                Text("文章记录 · \(articles.records.filter { $0.status == .saved }.count) 篇已保存").font(.system(size: 14, weight: .semibold))
                Spacer()
                TextField("搜索标题或公众号", text: $search).textFieldStyle(ShiyingGlassFieldStyle()).frame(maxWidth: 220)
            }
            if shown.isEmpty {
                Text("添加文章后，点击封面打开正文。正文和原图可逐篇或批量保存。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 18)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(shown) { record in
                    ShiyingArticleTile(record: record, coverCacheRoot: articles.coverCacheRoot,
                        open: { articles.showPreview(record) }, reveal: { articles.reveal(record) },
                        save: { articles.save(record) }, browser: { articles.openBrowser(record) }, remove: { articles.remove(record) })
                        .disabled(articles.busy)
                }
            }
        }
        .onAppear { articles.prepareCards(ids: Array(shown.prefix(200).map(\.id))) }
        .onChange(of: shown.map(\.id)) { _, _ in articles.prepareCards(ids: Array(shown.prefix(200).map(\.id))) }
        .onDisappear { articles.stopMonitoring() }
        .sheet(item: $articles.preview) { preview in ArticlePreviewSheet(preview: preview).environmentObject(articles) }
        .sheet(isPresented: $articles.browserVisible) {
            VStack(alignment: .leading,spacing: 12) {
                HStack {
                    Text("公众号原文").font(.system(size: 17,weight: .semibold)); Spacer()
                    Button("关闭") { articles.browserVisible = false }.buttonStyle(QQSoftButtonStyle())
                    Button("读取当前正文") { articles.readBrowser() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.teal)).disabled(articles.busy)
                }
                Text("看到完整文章后，点击「读取当前正文」。如网页要求验证，请先在此完成。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let error = articles.error { Text(error).font(.system(size: 12)).foregroundStyle(QQTheme.orange) }
                ArticleLiveWebView(webView: articles.loader.webView).frame(maxWidth: .infinity,maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
            }.padding(18).frame(width: 840,height: 700)
        }
    }
}

private struct ArticlePreviewSheet: View {
    @EnvironmentObject var articles: ArticleStore
    let preview: ArticlePreview
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack {
                Text(preview.title).font(.system(size: 16,weight: .semibold)).lineLimit(2); Spacer()
                Button("关闭") { articles.preview = nil }.buttonStyle(QQSoftButtonStyle())
                if let id = preview.recordID, let record = articles.records.first(where: { $0.id == id }), record.status != .saved {
                    Button("保存正文和图片") { articles.preview = nil; articles.save(record) }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.teal)).disabled(articles.busy)
                }
            }
            if let issue { Text(issue).font(.system(size: 12)).foregroundStyle(QQTheme.orange) }
            ArticleOfflineWebView(path: preview.path,onFailure: { issue = $0 })
                .frame(maxWidth: .infinity,maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
        }.padding(18).frame(width: 840,height: 720)
            .onDisappear { articles.discardPreview(preview.path) }
    }
}
private struct ArticleLiveWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView,context: Context) {}
}
private struct ArticleOfflineWebView: NSViewRepresentable {
    let path: String
    let onFailure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(path: path,onFailure: onFailure) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration();config.defaultWebpagePreferences.allowsContentJavaScript = false;config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero,configuration: config);view.navigationDelegate = context.coordinator
        let root = URL(fileURLWithPath: path,isDirectory: true).resolvingSymlinksInPath()
        view.loadFileURL(root.appendingPathComponent("文章.html"),allowingReadAccessTo: root);return view
    }
    func updateNSView(_ nsView: WKWebView,context: Context) {}
    final class Coordinator: NSObject,WKNavigationDelegate {
        let root: URL
        let onFailure: (String) -> Void
        init(path: String,onFailure: @escaping (String) -> Void) { root = URL(fileURLWithPath: path,isDirectory: true).resolvingSymlinksInPath(); self.onFailure = onFailure }
        func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            decisionHandler(url?.absoluteString == "about:blank" || (url?.isFileURL == true && url!.resolvingSymlinksInPath().path.hasPrefix(root.path + "/")) ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView,didFail navigation: WKNavigation!,withError error: Error) { onFailure("正文预览未能加载，请关闭后重试；已保存文件保留。") }
        func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: Error) { onFailure("正文预览无法打开，请检查保存文件是否仍在原位置。") }
    }
}
