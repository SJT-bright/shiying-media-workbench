import SwiftUI
import WebKit

/// 只管理拾影自己的抖音网页，不读取其它浏览器的会话。分区是持久的，关闭窗口后仍保持登录。
@MainActor
final class CreatorLoginBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var loading = true
    @Published var issue: String?
    private let homepage: URL
    let platform: MediaPlatform
    @Published var address: String
    @Published private(set) var capturedCount = 0

    init(url: URL, platform: MediaPlatform = .douyin) {
        homepage = url
        self.platform = platform
        address = url.absoluteString
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = CreatorLoginPersistence.dataStore(for: platform)
        if platform == .wechat || platform == .xiaohongshu || platform == .bilibili {
            configuration.userContentController.addUserScript(WKUserScript(source: PlatformWebCapture.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 与签名采集组件的桌面指纹一致。实际渲染仍由系统 WebKit 完成。
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        reload()
    }

    static func allowed(_ url: URL?, platform: MediaPlatform = .douyin) -> Bool {
        guard let url else { return false }
        return platform.allowsNavigation(url)
    }
    func openAddress() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), Self.allowed(url, platform: platform) else {
            issue = "请输入\(platform.title)的 HTTPS 官方网页链接。"
            return
        }
        issue = nil; loading = true; webView.load(URLRequest(url: url))
    }

    func reload() {
        issue = nil
        loading = true
        webView.load(URLRequest(url: homepage))
    }

    func readSession(_ completion: @escaping (Data) -> Void, capture: Bool = false) {
        issue = nil
        if capture {
            webView.evaluateJavaScript("window.__shiyingCapture ? window.__shiyingCapture.read() : null") { [weak self] value, _ in
                guard let self else { return }
                guard let result = value as? [String: Any], let raw = result["capturedPosts"] as? [[String: Any]] else {
                    self.issue = "当前网页尚未提供可采集媒体，请打开视频后重试。"; return
                }
                let posts = raw.filter { item in
                    if self.platform == .bilibili {
                        return (item["link"] as? String).map { MediaPlatform.detect(link: $0) == .bilibili } == true
                    }
                    guard let media = item["mediaURL"] as? String else { return false }
                    return PlatformWebCapture.acceptedMediaURL(media, platform: self.platform)
                }
                self.capturedCount = posts.count
                guard !posts.isEmpty else {
                    self.issue = result["encrypted"] as? Bool == true
                        ? "这个网页返回加密媒体，暂不能保存。请使用平台提供的下载入口。"
                        : "当前页面没有可直接保存的视频。请先打开并播放视频；blob 媒体暂不能直接保存。"
                    return
                }
                self.readCookies(capture: ["captureSource": result["captureSource"] ?? self.address,
                                           "capturedPosts": posts, "capturePartial": true], completion)
            }
        } else { readCookies(capture: nil, completion) }
    }

    private func readCookies(capture: [String: Any]?, _ completion: @escaping (Data) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let objects = CreatorStore.sessionCookieObjects(cookies, platform: self.platform)
            let hasAuth = self.platform.hasAuthenticationCookies(objects)
            guard hasAuth || capture != nil else {
                self.issue = "这个窗口尚未取得可验证的登录凭据。请先完成\(self.platform.title)登录。网页本身仍保留在独立分区。"; return
            }
            if let problem = CreatorStore.cookieValidationIssue(objects, platform: self.platform) {
                self.issue = "同步网页登录失败：" + problem + "现有网页登录保留。"
                return
            }
            var envelope: [String: Any] = ["version": 1, "platform": self.platform.rawValue, "cookies": objects]
            if let capture { envelope.merge(capture) { _, new in new } }
            let payload: Any = self.platform == .douyin ? objects : envelope
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  CreatorStore.acceptedSession(data, platform: self.platform) != nil else {
                self.issue = "登录信息结构或容量校验失败（session_schema）。\(objects.count) 项登录信息；现有网页登录保留。请复制此提示用于排查。"; return
            }
            completion(data)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 不放行外部 App 唤起；子框架的 CDN/验证码资源由 WebKit 正常处理。
        let main = navigationAction.targetFrame?.isMainFrame != false
        if main && !Self.allowed(navigationAction.request.url, platform: platform) {
            issue = "此窗口只允许\(platform.title)官方网页。"
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if Self.allowed(navigationAction.request.url, platform: platform) { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; address = webView.url?.absoluteString ?? address }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed() }
    }
    private func failed() {
        loading = false
        issue = "\(platform.title)页面加载失败，请检查网络后重新加载。"
    }
    func stop() { webView.stopLoading() }
}

private struct CreatorWebPage: NSViewRepresentable {
    let browser: CreatorLoginBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct CreatorLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: CreatorLoginBrowser
    private let platform: MediaPlatform
    private let parserLogin: Bool
    private let name: String
    private let willResume: Bool
    private let onSession: (Data) -> Void

    init(url: URL, name: String, willResume: Bool, platform: MediaPlatform = .douyin, parserLogin: Bool = false, onSession: @escaping (Data) -> Void) {
        _browser = StateObject(wrappedValue: CreatorLoginBrowser(url: url, platform: platform))
        self.platform = platform
        self.parserLogin = parserLogin
        self.name = name
        self.willResume = willResume
        self.onSession = onSession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(parserLogin ? "微信扫码登录元宝，解析视频号分享链接" : (name.isEmpty ? "登录\(platform.title)，保持这个网页登录" : "登录\(platform.title)，采集\(name)的作品"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(platform == .douyin || parserLogin ? "登录后可直接关闭此窗口；开始解析或采集时会自动同步这里的登录。退出拾影后仍保留在这台 Mac。" : "每个平台使用独立的网页登录。关闭窗口和退出拾影后仍保留在这台 Mac。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose))
            }
            HStack(spacing: 8) {
                TextField("官方主页或视频链接", text: $browser.address)
                    .textFieldStyle(ShiyingGlassFieldStyle()).onSubmit { browser.openAddress() }
                Button("打开网页") { browser.openAddress() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
            }
            if platform == .wechat || platform == .xiaohongshu || platform == .bilibili {
                Text(platform == .wechat
                     ? (parserLogin ? "解析通过腾讯元宝和视频号的官方接口完成。请在下方用微信扫码登录元宝，再点击保存登录。博主全部作品尚不支持；遇到加密媒体会明确提示。" : "视频号分享预览可能只显示微信二维码。此时请关闭窗口，使用「登录元宝解析视频号」；此窗口仅捕获实际加载的可保存视频。")
                     : "可在博主主页继续滚动或打开作品，再采集已经加载的视频。网页采集只代表当前可见范围。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            CreatorWebPage(browser: browser)
                .overlay(alignment: .top) { if browser.loading { ProgressView().padding(8) } }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(minHeight: 400)
            if let issue = browser.issue {
                Text(issue).font(.system(size: 12)).foregroundStyle(QQTheme.orange)
            }
            HStack(alignment: .center, spacing: 12) {
                Text("登录只保存在这台 Mac 的拾影里。是否有效由平台确认；可以在主页清除当前平台的登录。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("重新加载") { browser.reload() }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                if !parserLogin && (platform == .wechat || platform == .xiaohongshu || platform == .bilibili) {
                    Button("采集网页视频") { browser.readSession(onSession, capture: true) }
                        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan)).disabled(browser.loading)
                }
                Button { browser.readSession(onSession) } label: {
                    Label(parserLogin ? (willResume ? "保存元宝登录并解析分享" : "保存元宝登录") : (willResume ? "使用此窗口登录状态补采" : "保持这个登录"), systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan, compact: true))
                .disabled(browser.loading)
            }
        }
        .padding(20)
        .background { ShiyingWallpaper() }
        .frame(width: 1000, height: 700)
        .onDisappear { browser.stop() }
    }
}
