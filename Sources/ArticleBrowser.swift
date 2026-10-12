import Foundation
import WebKit

/// A distinct app-owned partition; no browser/WeChat-client credential extraction.
@MainActor final class ArticlePageLoader: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var completion: ((Result<[String: Any], Error>) -> Void)?
    private var token = UUID()
    private var requestedLink: String?
    private var resolvedLink: String?
    init(testing: Bool = false) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = testing ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: UUID(uuidString: "7C5E9123-77BA-4CD6-9C2A-52C8D135EA03")!)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(); webView.navigationDelegate = self
    }
    func load(_ link: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        cancel(); self.completion = completion; let run = token
        guard let url = URL(string: link) else { finish(.failure(WorkStatisticsError(message: "文章链接无效。"))); return }
        requestedLink = link; resolvedLink = nil
        webView.load(URLRequest(url: url))
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self, self.token == run, self.completion != nil else { return }
            self.finish(.failure(WorkStatisticsError(message: "读取文章超过35秒，请在内置网页检查后重试。")))
        }
    }
    func cancel() { token = UUID(); completion = nil; webView.stopLoading() }
    private func finish(_ result: Result<[String: Any], Error>) { let callback = completion; completion = nil; callback?(result) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated,
           let article = try? ArticleInput.canonical(url.absoluteString),
           article != requestedLink && article != resolvedLink {
            decisionHandler(.cancel)
            finish(.failure(WorkStatisticsError(message: "当前正在读取这一篇文章。请把另一篇文章链接添加到文章列表。")))
            return
        }
        if url.absoluteString == "about:blank" || (url.scheme == "https" && url.host == "mp.weixin.qq.com" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)) {
            decisionHandler(.allow)
        } else { decisionHandler(.cancel); finish(.failure(WorkStatisticsError(message: "文章跳转到了非公众号页面，已停止读取。"))) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if completion != nil, let url = webView.url { resolvedLink = try? ArticleInput.canonical(url.absoluteString) }
        capture(attempt: 0)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(WorkStatisticsError(message: "公众号网页加载失败，请检查网络后重试。"))) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(WorkStatisticsError(message: "公众号网页无法打开，请检查链接或网络。"))) }
    func captureCurrent(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        token = UUID(); self.completion = completion
        guard let current = webView.url.flatMap({ try? ArticleInput.canonical($0.absoluteString) }),
              current == requestedLink || current == resolvedLink else {
            finish(.failure(WorkStatisticsError(message: "当前网页尚未返回本次文章，请打开原文并完成微信要求的验证后重试。"))); return
        }
        capture(attempt: 2)
    }
    private func capture(attempt: Int) {
        guard completion != nil else { return }
        let run = token
        let documentURL = webView.url
        // Only public article fields and #js_content enter the Python helper.
        // Scripts, full page HTML, cookies, local storage and authentication URL are never exported.
        let script = #"""
        (() => {
          const node=document.querySelector('#js_content');
          if(!node || !(node.textContent.trim() || node.querySelector('img[data-src],img[src]'))) return null;
          const text=s=>document.querySelector(s)?.textContent.trim() || '';
          const meta=n=>document.querySelector('meta[property="'+n+'"],meta[name="'+n+'"]')?.content || '';
          const copy=node.cloneNode(true);
          copy.querySelectorAll('.video_iframe,.wx_video_iframe,mp-common-videos,mp-video,mpvoice,qqmusic,video').forEach(n=>{if(!copy.contains(n))return;const p=document.createElement('p');p.textContent='【原文含音视频，本次保存正文和图片。】';n.replaceWith(p);});
          copy.querySelectorAll('script,style,noscript,iframe,object,embed,form,input,button,template').forEach(n=>n.remove());
          return {title:text('#activity-name')||meta('og:title'),account:text('#js_name'),author:text('#js_author_name')||meta('author'),published:text('#publish_time'),coverURL:meta('og:image'),excerpt:copy.textContent.trim().replace(/\s+/g,' ').slice(0,2000),
            html:copy.outerHTML};
        })()
        """#
        webView.evaluateJavaScript(script) { [weak self] value, error in
            MainActor.assumeIsolated {
                guard let self, self.token == run, self.completion != nil else { return }
                guard self.webView.url == documentURL else {
                    self.finish(.failure(WorkStatisticsError(message: "网页在读取期间发生跳转，请确认当前文章后重新读取。"))); return
                }
                if let snapshot = value as? [String: Any], let body = snapshot["html"] as? String, body.utf8.count <= 2_097_152 {
                    self.finish(.success(snapshot))
                } else if attempt < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in guard let self, self.token == run else { return }; self.capture(attempt: attempt + 1) }
                } else {
                    self.finish(.failure(WorkStatisticsError(message: "网页没有返回文章正文，可能需要微信验证、文章已删除或链接失效。打开内置网页检查后，点击「读取当前正文」。")))
                }
            }
        }
    }
}

/// Monitoring-only page reader. It never shares the verification web view, never returns article HTML,
/// and never reads cookies, storage, or page globals. A zero-size view can make every public count look hidden,
/// so this one keeps a real layout size even though it is not shown.
struct ArticleMetadataCancelled: Error {}

@MainActor final class ArticleMetadataLoader: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var completion: ((Result<[String: Any], Error>) -> Void)?
    private var token = UUID()
    private var requestedLink: String?
    private var resolvedLink: String?
    private var extractsStatistics = true
    init(testing: Bool = false) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = testing ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: UUID(uuidString: "7C5E9123-77BA-4CD6-9C2A-52C8D135EA03")!)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 2400), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }
    func fetch(_ link: String) async -> Result<[String: Any], Error> {
        await withCheckedContinuation { continuation in
            load(link) { continuation.resume(returning: $0) }
        }
    }
    func fetchPresentation(_ link: String) async -> Result<[String: Any], Error> {
        await withCheckedContinuation { continuation in
            load(link, extractsStatistics: false) { continuation.resume(returning: $0) }
        }
    }
    func load(_ link: String, extractsStatistics: Bool = true, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        cancel()
        self.extractsStatistics = extractsStatistics
        self.completion = completion
        let run = UUID(); token = run
        guard let url = URL(string: link) else {
            finish(.failure(WorkStatisticsError(message: "文章链接无效。"))); return
        }
        requestedLink = link; resolvedLink = nil
        webView.load(URLRequest(url: url))
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self, self.token == run, self.completion != nil else { return }
            self.finish(.failure(WorkStatisticsError(message: "检查公开数据超过35秒，原有互动数据保留。")))
        }
    }
    /// Completes an in-flight read exactly once so a waiting check cannot observe a stale page.
    func cancel() {
        token = UUID(); webView.stopLoading(); finish(.failure(ArticleMetadataCancelled()))
    }
    private func finish(_ result: Result<[String: Any], Error>) {
        let callback = completion; completion = nil
        guard let callback else { return }
        DispatchQueue.main.async { callback(result) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated,
           let article = try? ArticleInput.canonical(url.absoluteString),
           article != requestedLink && article != resolvedLink {
            decisionHandler(.cancel)
            finish(.failure(WorkStatisticsError(message: "检查跳到了另一篇文章，原有互动数据保留。")))
            return
        }
        if url.absoluteString == "about:blank" || (url.scheme == "https" && url.host == "mp.weixin.qq.com" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)) {
            decisionHandler(.allow)
        } else { decisionHandler(.cancel); finish(.failure(WorkStatisticsError(message: "文章跳转到了非公众号页面，已停止检查。原有互动数据保留。"))) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if completion != nil, let url = webView.url { resolvedLink = try? ArticleInput.canonical(url.absoluteString) }
        capture(attempt: 0)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WorkStatisticsError(message: "公众号网页加载失败，原有互动数据保留。")))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WorkStatisticsError(message: "公众号网页无法打开，原有互动数据保留。")))
    }
    private func capture(attempt: Int) {
        guard completion != nil else { return }
        let run = token
        let documentURL = webView.url
        webView.layoutSubtreeIfNeeded()
        // Visible text only. No html, cookie, storage, or window/appmsg/cgiData globals.
        // 点赞 is #old_likeNum; 在看 is #likeNum. Same selectors as the full-article reader.
        let script = #"""
        (() => {
          if(!document.documentElement || !document.documentElement.getClientRects().length) return null;
          const node=document.querySelector('#js_content');
          if(!node || !(node.textContent.trim() || node.querySelector('img[data-src],img[src]'))) return null;
          const meta=n=>document.querySelector('meta[property="'+n+'"],meta[name="'+n+'"]')?.content || '';
          const text=s=>document.querySelector(s)?.textContent.trim() || '';
          const count=selectors=>{
            for(const selector of selectors){const n=document.querySelector(selector);if(!n || !n.getClientRects().length || getComputedStyle(n).visibility!=="visible")continue;
              const t=n.textContent.trim();if(t.length<=32 && /^(?:[0-9]{1,12}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?)(?:万|亿)?\+?$/.test(t))return t;}return null;};
          return {title:text('#activity-name')||meta('og:title'),account:text('#js_name'),author:text('#js_author_name')||meta('author'),published:text('#publish_time'),coverURL:meta('og:image'),excerpt:node.textContent.trim().replace(/\s+/g,' ').slice(0,2000),
            statistics:\#(extractsStatistics ? "{read:count(['#readNum','#js_read_num']),like:count(['#old_likeNum','#js_like_num']),watching:count(['#likeNum','#js_wow_num']),comments:count(['#js_comment_count'])}" : "{}")};
        })()
        """#
        webView.evaluateJavaScript(script) { [weak self] value, error in
            MainActor.assumeIsolated {
                guard let self, self.token == run, self.completion != nil else { return }
                guard self.webView.url == documentURL else {
                    self.finish(.failure(WorkStatisticsError(message: "网页在检查期间发生跳转，原有互动数据保留。"))); return
                }
                if let snapshot = value as? [String: Any], let publicFields = self.publicFields(snapshot) {
                    self.finish(.success(publicFields))
                } else if attempt < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in guard let self, self.token == run else { return }; self.capture(attempt: attempt + 1) }
                } else {
                    self.finish(.failure(WorkStatisticsError(message: "网页没有返回可检查的文章，可能需要微信验证、文章已删除或链接失效。原有互动数据保留。")))
                }
            }
        }
    }
    /// Copies only the four public counters plus the short cover and excerpt. Everything else is dropped.
    private func publicFields(_ value: [String: Any]) -> [String: Any]? {
        guard let statistics = value["statistics"] as? [String: Any] else { return nil }
        var metrics: [String: Any] = [:]
        for key in ["read", "like", "watching", "comments"] {
            if let entry = statistics[key], !(entry is NSNull) { metrics[key] = entry }
        }
        var snapshot: [String: Any] = ["statistics": metrics]
        for (key, limit) in [("title", 1000), ("account", 200), ("author", 200), ("published", 100)] {
            if let value = value[key] as? String, !value.isEmpty { snapshot[key] = String(value.prefix(limit)) }
        }
        if let cover = value["coverURL"] as? String, cover.count <= 4_096 { snapshot["coverURL"] = cover }
        if let excerpt = value["excerpt"] as? String, excerpt.count <= 4_000 { snapshot["excerpt"] = excerpt }
        return snapshot
    }
}
