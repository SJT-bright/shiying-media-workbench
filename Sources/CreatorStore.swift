import Foundation
import Darwin
import Combine
import WebKit

// 博主扫描状态。不引用 Store / BatchStore，不写批量资料库；作品结果只在内存。
// 登录只来自拾影自己的网页窗口，写入本机 creator-session.json，退出后仍可采集。
// 过滤和排序只调用 CreatorCore，这里不复制门槛数学。

@MainActor
enum CreatorLoginPersistence {
    // WKHTTPCookieStore does not own the store. Keep the partition alive while
    // asynchronous reads run, including before any login webview is opened.
    private static var stores: [MediaPlatform: WKWebsiteDataStore] = [:]
    private static var warmups: [UUID: CreatorCookieWarmup] = [:]
    static var dataStore: WKWebsiteDataStore { dataStore(for: .douyin) }
    static func dataStore(for platform: MediaPlatform) -> WKWebsiteDataStore {
        if shiyingTestDataRoot(fallback: "/tmp/shiying-creator-session-test") != nil || CreatorStore.sessionFileOverride != nil {
            return .nonPersistent()
        }
        if let store = stores[platform] { return store }
        let store = WKWebsiteDataStore(forIdentifier: platform.websiteIdentifier)
        stores[platform] = store
        return store
    }
    static func eraseWebsiteData(for platform: MediaPlatform = .douyin) {
        dataStore(for: platform).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
    static func readSessionCookies(for platform: MediaPlatform, completion: @escaping ([HTTPCookie]) -> Void) {
        let store = dataStore(for: platform)
        store.httpCookieStore.getAllCookies { cookies in
            let authenticated = platform.hasAuthenticationCookies(CreatorStore.sessionCookieObjects(cookies, platform: platform))
            guard platform == .wechat, !authenticated, CreatorStore.sessionForWorker(platform: platform) == nil else {
                completion(cookies); return
            }
            // A cold WebKit partition can enumerate no cookies until a webview
            // starts its network process. Initialize only our existing Yuanbao
            // partition; do not ask the user to sign in again or read other apps.
            let id = UUID()
            let warmup = CreatorCookieWarmup(store: store)
            warmups[id] = warmup
            warmup.start { loaded in
                warmups.removeValue(forKey: id)
                completion(loaded.isEmpty ? cookies : loaded)
            }
        }
    }
}

@MainActor
private final class CreatorCookieWarmup: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var completion: (([HTTPCookie]) -> Void)?
    init(store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    }
    func start(_ completion: @escaping ([HTTPCookie]) -> Void) {
        self.completion = completion
        webView.load(URLRequest(url: MediaPlatform.wechatParserLoginURL))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.readCookies() }
    }
    private func readCookies() {
        guard completion != nil else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, let callback = self.completion else { return }
            self.completion = nil
            self.webView.stopLoading()
            callback(cookies)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { readCookies() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { readCookies() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { readCookies() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let main = navigationAction.targetFrame?.isMainFrame != false
        decisionHandler(!main || navigationAction.request.url.map { MediaPlatform.wechat.allowsNavigation($0) } == true ? .allow : .cancel)
    }
}

@MainActor
final class CreatorStore: ObservableObject {
    var otherTaskIsBusy: () -> Bool = { false }
    @Published private(set) var platform: MediaPlatform = .douyin
    @Published var urlText = ""
    @Published var posts: [CreatorPost] = [] { didSet { invalidatePresentationCache() } }
    @Published var selectedIDs: Set<String> = [] { didSet { cachedSelectedPosts = nil } }
    @Published var filter = CreatorFilter() { didSet { cachedFilteredPosts = nil; cachedSelectedPosts = nil; cachedUnknownCount = nil } }
    @Published var isScanning = false
    @Published var detail = ""
    @Published var error: String?
    @Published var creatorName = ""
    @Published var pageCount = 0
    @Published var scannedCount = 0
    @Published var scanComplete = false
    @Published private(set) var shareResolved = false
    @Published var nextCursor: String?
    @Published var needsLogin = false
    @Published private(set) var hasSession = false
    @Published private(set) var homepageURL: URL?
    @Published private(set) var diagnosticText = ""
    private(set) var sourceURL = ""
    private var subscriptionHomepageScan = false
    private var sessionData: Data?
    private var sessionPersistenceError: String?
    private var recoveryRun = false
    private var currentRunIDs: Set<String> = []

    /// 仅测试宿主注入 worker 路径。正式启动不读这个值，也不传 --test-mode。
    static var workerOverrideURL: URL?

    /// 仅测试宿主把登录文件指到临时路径。正式启动不设置，写到 Application Support。
    static var sessionFileOverride: URL?
    /// Test-only callback; production always reads this app's WebKit partition.
    static var sessionCookieReaderOverride: ((@escaping ([HTTPCookie]) -> Void) -> Void)?

    /// 可下载结果只含视频。非视频仍留在 posts 里供计数，但不进筛选、勾选和全选。
    // SwiftUI reads these from the sidebar, header, footer and rows in the same update.
    // Reuse one snapshot until posts, filter or selection actually change.
    private var cachedVideoPosts: [CreatorPost]?
    private var cachedFilteredPosts: [CreatorPost]?
    private var cachedSelectedPosts: [CreatorPost]?
    private var cachedUnknownCount: Int?
    private func invalidatePresentationCache() {
        cachedVideoPosts = nil; cachedFilteredPosts = nil
        cachedSelectedPosts = nil; cachedUnknownCount = nil
    }
    private var videoPosts: [CreatorPost] {
        if let cachedVideoPosts { return cachedVideoPosts }
        let value = posts.filter(\.isVideo); cachedVideoPosts = value; return value
    }
    var skippedNonVideoCount: Int { posts.count - videoPosts.count }
    var filteredPosts: [CreatorPost] {
        if let cachedFilteredPosts { return cachedFilteredPosts }
        let value = CreatorCore.apply(videoPosts, filter: filter); cachedFilteredPosts = value; return value
    }
    var selectedPosts: [CreatorPost] {
        if let cachedSelectedPosts { return cachedSelectedPosts }
        let value = filteredPosts.filter { selectedIDs.contains($0.id) }; cachedSelectedPosts = value; return value
    }
    var unknownFieldCount: Int {
        if let cachedUnknownCount { return cachedUnknownCount }
        let value = CreatorCore.unknownFieldCount(videoPosts, filter: filter); cachedUnknownCount = value; return value
    }
    var filterError: String? { CreatorCore.validate(filter) }

    /// 最近一条进度或完成事件里的 received。JSON 的 0 要留下来，不能被 Bool 桥接丢掉。
    var progressReceived: Int?

    /// 当前扫描代际。测试用来确认迟到事件被丢掉。
    var scanGeneration: UUID { generation }

    private var process: Process?
    private var generation = UUID()
    var scannedCreatorID: String? { creatorID }
    var hasScanReceipt: Bool { sawTerminal && !blocked }
    private(set) var scanCancelled = false
    private var creatorID: String?
    private var pageBase = 0
    private var cancelRequested = false
    private var resumeLocked = false
    private var blocked = false
    private var sawTerminal = false
    private var homepageCount: Int?
    /// 上一批出现过无法解析或作者错配。续扫必须带上，不能在下一批被洗成全部。
    private var carryPartial = false
    private var seenIDsFile: URL?

    init() { restoreSession() }

    private func restoreSession() {
        let url = Self.sessionFileURL(platform: platform)
        sessionData = Self.acceptedSession(at: url, platform: platform)
        hasSession = sessionData != nil
        if FileManager.default.fileExists(atPath: url.path), sessionData == nil {
            error = "\(platform.title)登录文件无法读取或已失效，原文件保留。请打开内置网页重新保持登录。"
        }
    }

    func selectPlatform(_ next: MediaPlatform) {
        guard !isScanning, next != platform else { return }
        generation = UUID()
        platform = next
        urlText = ""; posts = []; selectedIDs = []; creatorName = ""; creatorID = nil
        homepageURL = nil; sourceURL = ""; pageCount = 0; scannedCount = 0
        scanComplete = false; shareResolved = false; nextCursor = nil; needsLogin = false
        filter = CreatorFilter(); progressReceived = nil; carryPartial = false
        recoveryRun = false; currentRunIDs = []; sessionPersistenceError = nil
        error = nil; detail = ""; diagnosticText = ""; deleteSeenFile()
        restoreSession()
    }

    func scan(resume: Bool = false, authenticatedRecovery: Bool = false, subscriptionUpdate: Bool = false) {
        guard !isScanning, !otherTaskIsBusy() else { return }
        scanCancelled = false; sawTerminal = false; blocked = false
        subscriptionHomepageScan = subscriptionUpdate
        // The embedded website is the source of truth. A user who logged in and
        // closed the sheet must not silently start a guest request.
        guard (platform == .douyin || platform == .wechat), Self.workerOverrideURL == nil || Self.sessionCookieReaderOverride != nil else {
            beginScan(resume: resume, authenticatedRecovery: authenticatedRecovery)
            return
        }
        guard !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authenticatedRecovery || (resume && homepageURL != nil) else {
            error = "请粘贴博主主页链接。"; return
        }
        isScanning = true
        shareResolved = false
        diagnosticText = ""
        let loginName = platform == .wechat ? "元宝" : platform.title
        detail = "正在同步内置\(loginName)网页的登录状态…"
        generation = UUID()
        let token = generation
        let currentPlatform = platform
        let readCookies: (@escaping ([HTTPCookie]) -> Void) -> Void = Self.sessionCookieReaderOverride ?? {
            CreatorLoginPersistence.readSessionCookies(for: currentPlatform, completion: $0)
        }
        readCookies { [weak self] cookies in
            guard let self, self.generation == token, self.isScanning else { return }
            self.isScanning = false
            switch Self.sessionFromCookies(cookies, platform: currentPlatform) {
            case .success(let data):
                if let data { self.rememberSession(data) }
                // A valid saved session remains usable when WebKit hasn't loaded
                // its partition yet; the server still verifies the credential.
                self.beginScan(resume: resume, authenticatedRecovery: authenticatedRecovery)
            case .failure(let issue):
                self.error = issue.message
                self.detail = issue.message
                self.diagnosticText = "阶段：同步内置网页登录\n" + issue.message
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == token, self.isScanning, self.process == nil else { return }
            self.generation = UUID(); self.isScanning = false
            self.error = "读取内置\(loginName)登录超过 10 秒，采集尚未开始。请重新打开内置网页登录页后重试；已有登录和作品保留。"
            self.detail = self.error ?? ""
        }
    }

    private func beginScan(resume: Bool = false, authenticatedRecovery: Bool = false) {
        guard !isScanning else { return }
        shareResolved = false
        let recovery = authenticatedRecovery && homepageURL != nil && sessionData != nil
        let link = ((recovery || resume) ? (homepageURL?.absoluteString ?? sourceURL) : urlText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            error = "请粘贴博主主页链接。"
            return
        }
        guard MediaPlatform.detect(link: link) == platform else {
            error = "当前选择的是\(platform.title)，请粘贴对应平台的官方链接，或切换平台。"
            return
        }
        let cursor = nextCursor
        if resume {
            guard let cursor, !cursor.isEmpty else {
                error = "没有可继续的位置，请重新扫描。"
                return
            }
            pageBase = pageCount
            resumeLocked = true
        } else if !recovery {
            posts = []
            selectedIDs = []
            creatorName = ""
            creatorID = nil
            homepageURL = nil
            pageCount = 0
            scannedCount = 0
            scanComplete = false
            nextCursor = nil
            pageBase = 0
            resumeLocked = false
            homepageCount = nil
            progressReceived = nil
            carryPartial = false
            deleteSeenFile()
        } else {
            // 从首页重新扫描，旧结果、筛选和用户勾选保留；逐条按 ID 更新、补齐。
            pageBase = 0
            resumeLocked = true
            carryPartial = false
            nextCursor = nil
            progressReceived = nil
            deleteSeenFile()
            urlText = link
        }
        if !resume { sourceURL = link }
        recoveryRun = recovery || (resume && recoveryRun)
        if !resume { currentRunIDs = [] }
        needsLogin = false
        diagnosticText = ""
        blocked = false
        cancelRequested = false
        sawTerminal = false
        error = sessionPersistenceError
        scanComplete = false
        isScanning = true
        detail = resume ? "正在继续扫描" : "正在解析主页"
        generation = UUID()
        let token = generation

        guard let worker = Self.workerOverrideURL
                ?? Bundle.main.resourceURL?.appendingPathComponent("worker/拾影Worker"),
              FileManager.default.isExecutableFile(atPath: worker.path) else {
            isScanning = false
            error = "扫描组件缺失，请重新安装 App。"
            return
        }
        var arguments = ["scan", "--link", link]
        if platform != .douyin { arguments += ["--platform", platform.rawValue] }
        var workerSession = sessionData
        if subscriptionHomepageScan, platform == .bilibili, let data = workerSession,
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object.removeValue(forKey: "capturedPosts")
            workerSession = try? JSONSerialization.data(withJSONObject: object)
        }
        let input = workerSession.map { _ in Pipe() }
        if input != nil { arguments += ["--session-stdin"] }
        if resume, let cursor {
            arguments += ["--resume-cursor", cursor]
            if carryPartial {
                arguments += ["--prior-partial"]
            }
            switch makeSeenFile() {
            case .invalid:
                isScanning = false
                error = "已采编号无法写入续扫文件，请重新扫描。"
                detail = error ?? detail
                deleteSeenFile()
                return
            case .empty:
                break
            case .ready(let url):
                seenIDsFile = url
                arguments += ["--seen-ids-file", url.path]
            }
        }
        let process = Process()
        process.executableURL = worker
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let input { process.standardInput = input }
        self.process = process
        do {
            try process.run()
        } catch {
            self.process = nil
            isScanning = false
            deleteSeenFile()
            self.error = "扫描组件启动失败：\(error.localizedDescription)"
            return
        }
        if cancelRequested { process.terminate() }

        if let input, let data = workerSession {
            DispatchQueue.global(qos: .utility).async {
                defer { try? input.fileHandleForWriting.close() }
                do { try input.fileHandleForWriting.write(contentsOf: data) }
                catch {
                    DispatchQueue.main.async {
                        guard token == self.generation, self.isScanning else { return }
                        self.error = "登录状态传递失败，请重新登录。"
                        self.sawTerminal = true
                        process.terminate()
                    }
                }
            }
        }

        DispatchQueue.global(qos: .utility).async { _ = stderr.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { self.handle(event, token: token) }
                    }
                }
            }
            process.waitUntilExit()
            let code = process.terminationStatus
            DispatchQueue.main.async { self.finish(token: token, code: code) }
        }
    }

    func cancel() {
        guard isScanning else { return }
        scanCancelled = true
        if process == nil {
            generation = UUID(); isScanning = false
            detail = "已取消登录同步，已采作品保留。"
            return
        }
        cancelRequested = true
        detail = "正在取消扫描…"
        process?.terminate()
    }

    func shutdown() {
        cancelRequested = true
        blocked = true
        generation = UUID()
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        isScanning = false
        deleteSeenFile()
    }

    /// 用户在内置网页点了使用登录状态。写入本机文件，退出 App 后仍然有效。
    /// 已经有主页就立刻用该账号补采；还没有主页就只待机，等用户去解析。
    func useSession(_ data: Data) {
        guard !isScanning, let accepted = Self.acceptedSession(data, platform: platform) else {
            error = "这个窗口没有可用的\(platform.title)登录状态或网页媒体。"
            return
        }
        rememberSession(accepted)
        if let envelope = try? JSONSerialization.jsonObject(with: accepted) as? [String: Any],
           let source = envelope["captureSource"] as? String, let url = URL(string: source),
           platform.allowsNavigation(url), (envelope["capturedPosts"] as? [[String: Any]])?.isEmpty == false {
            // 网页采集来源以用户实际打开的官方页面为准，不能挂到此前作者。
            urlText = source; homepageURL = nil
            scan()
        } else if platform == .wechat, MediaPlatform.detect(link: urlText) == .wechat {
            scan()
        } else if homepageURL != nil {
            scan(authenticatedRecovery: true)
        } else {
            needsLogin = false
            error = sessionPersistenceError
            detail = platform == .wechat ? "元宝解析登录已保存。粘贴视频号分享链接后点解析；是否有效由腾讯确认。" : "\(platform.title)网页登录已保存，粘贴主页后开始采集。是否仍有效由平台确认。"
        }
    }

    func rememberSession(_ data: Data) {
        guard let accepted = Self.acceptedSession(data, platform: platform) else { return }
        if accepted != sessionData || !FileManager.default.fileExists(atPath: Self.sessionFileURL(platform: platform).path) {
            sessionPersistenceError = persistSession(accepted)
        }
        sessionData = accepted; hasSession = true
        if let issue = sessionPersistenceError { error = issue }
    }

    static func cookieValidationIssue(_ rows: [[String: Any]], platform: MediaPlatform) -> String? {
        if rows.count > 256 { return "内置网页返回 \(rows.count) 项登录信息，超过 256 项上限。" }
        for (index, row) in rows.enumerated() {
            let prefix = "第 \(index + 1) 项网页登录信息"
            guard let name = row["name"] as? String, !name.isEmpty, name.count <= 128,
                  name.range(of: #"^[A-Za-z0-9_!#$%&*+.^`|~-]{1,128}$"#, options: .regularExpression) != nil else { return prefix + "的名称格式不受支持。" }
            // Empty cookie values are legal (including site feature flags). The
            // authentication check below separately requires a nonempty token.
            guard let value = row["value"] as? String, value.count <= 8192,
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return prefix + "的值过长或含控制字符。" }
            guard let domain = row["domain"] as? String, platform.acceptsCookieDomain(domain) else { return prefix + "不属于当前平台。" }
            guard let path = row["path"] as? String, path.hasPrefix("/"), path.count <= 2048,
                  !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return prefix + "的作用路径无效。" }
            if let expires = row["expires"] {
                guard let number = expires as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue > Date().timeIntervalSince1970,
                      number.doubleValue < 32_503_680_000 else { return prefix + "已过期或有效期无效。" }
            }
        }
        return nil
    }

    static func sessionCookieObjects(_ cookies: [HTTPCookie], platform: MediaPlatform) -> [[String: Any]] {
        cookies.filter { $0.expiresDate == nil || $0.expiresDate! > Date() }
            .sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
            .compactMap { cookie in
                guard let domain = platform.sessionCookieDomain(name: cookie.name, domain: cookie.domain) else { return nil }
                return ["name": cookie.name, "value": cookie.value, "domain": domain, "path": cookie.path]
            }
    }

    static func sessionFromCookies(_ cookies: [HTTPCookie], platform: MediaPlatform) -> Result<Data?, CreatorInputError> {
        let objects = sessionCookieObjects(cookies, platform: platform)
        guard platform.hasAuthenticationCookies(objects) else { return .success(nil) }
        if let issue = cookieValidationIssue(objects, platform: platform) { return .failure(CreatorInputError(message: "同步登录失败：" + issue + "原网页登录保留。")) }
        let payload: Any = platform == .douyin ? objects : ["version": 1, "platform": platform.rawValue, "cookies": objects]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return .failure(CreatorInputError(message: "登录信息序列化失败，采集尚未开始。"))
        }
        guard data.count <= (platform == .douyin ? 65536 : 1_048_576) else {
            return .failure(CreatorInputError(message: "网页登录信息为 \(data.count) 字节，超过采集组件容量；原网页登录保留。"))
        }
        guard acceptedSession(data, platform: platform) != nil else {
            return .failure(CreatorInputError(message: "登录信息结构校验未通过（session_schema），采集尚未开始；原网页登录保留。"))
        }
        return .success(data)
    }

    func clearSession() {
        guard !isScanning else { return }
        _ = invalidateSession()
    }

    @discardableResult private func invalidateSession() -> String? {
        let url = Self.sessionFileURL(platform: platform)
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch {
            self.error = "登录文件清除失败，未清除网页登录。请检查文件权限。"
            return self.error
        }
        sessionData = nil; hasSession = false; sessionPersistenceError = nil
        CreatorLoginPersistence.eraseWebsiteData(for: platform)
        return nil
    }

    static func sessionFileURL(platform: MediaPlatform = .douyin) -> URL {
        if let sessionFileOverride {
            return platform == .douyin ? sessionFileOverride : sessionFileOverride.deletingLastPathComponent().appendingPathComponent(platform.sessionFilename)
        }
        if let root = shiyingTestDataRoot(fallback: "/tmp/shiying-creator-session-test") {
            return root.appendingPathComponent(platform.sessionFilename)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/拾影/" + platform.sessionFilename)
    }

    static func sessionForWorker(platform: MediaPlatform) -> Data? {
        acceptedSession(at: sessionFileURL(platform: platform), platform: platform)
    }
    static func sessionForDownload(link: String) -> Data? {
        guard let platform = MediaPlatform.detect(link: link) else { return nil }
        return sessionForWorker(platform: platform)
    }

    /// Cookie 限于当前平台，登录及媒体只从本 App 的内置分区取得。
    static func acceptedSession(_ data: Data, platform: MediaPlatform = .douyin) -> Data? {
        guard !data.isEmpty, data.count <= (platform == .douyin ? 65536 : 1_048_576),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rows: [[String: Any]]
        var hasCapture = false
        if let envelope = object as? [String: Any] {
            guard let version = envelope["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1, version.doubleValue == 1,
                  envelope["platform"] as? String == platform.rawValue,
                  let cookies = envelope["cookies"] as? [[String: Any]] else { return nil }
            rows = cookies
            if let captures = envelope["capturedPosts"] as? [[String: Any]], !captures.isEmpty {
                guard (platform == .wechat || platform == .xiaohongshu || platform == .bilibili), captures.count <= 5000,
                      let source = envelope["captureSource"] as? String, let url = URL(string: source),
                      MediaPlatform.detect(link: source) == platform, platform.allowsNavigation(url) else { return nil }
                for post in captures {
                    guard let id = post["id"] as? String, !id.isEmpty, id.count <= 180,
                          let link = post["link"] as? String, let postURL = URL(string: link), MediaPlatform.detect(link: link) == platform, platform.allowsNavigation(postURL) else { return nil }
                    if platform == .bilibili {
                        guard postURL.path.range(of: #"^/video/(?:BV[A-Za-z0-9]+|av[0-9]+)/?$"#, options: .regularExpression) != nil else { return nil }
                    } else {
                        guard let media = post["mediaURL"] as? String, PlatformWebCapture.acceptedMediaURL(media, platform: platform) else { return nil }
                    }
                }
                hasCapture = true
            }
        } else if platform == .douyin, let cookies = object as? [[String: Any]] { rows = cookies }
        else { return nil }
        guard cookieValidationIssue(rows, platform: platform) == nil else { return nil }
        return platform.hasAuthenticationCookies(rows) || hasCapture ? data : nil
    }

    private static func acceptedSession(at url: URL, platform: MediaPlatform) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return acceptedSession(data, platform: platform)
    }

    private func persistSession(_ data: Data) -> String? {
        let url = Self.sessionFileURL(platform: platform)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".creator-session-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 从创建时起即 0600，完成写入后原子替换；没有短暂公开的凭据文件。
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            return nil
        } catch {
            return "登录状态在本次窗口生效，但写入本机失败，退出后需要重新登录。请检查磁盘空间和文件权限。"
        }
    }

    func selectAllFiltered() {
        selectedIDs.formUnion(filteredPosts.map(\.id))
    }

    func clearSelection() {
        selectedIDs = []
    }

    func toggleSelection(_ id: String) {
        guard let post = posts.first(where: { $0.id == id }), post.isVideo else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// 测试宿主可直接送入一行事件。token 不是当前代际时整段丢弃。
    func handle(_ event: [String: Any], token: UUID) {
        guard token == generation, !blocked else { return }
        if let incomingPlatform = event["platform"] as? String, incomingPlatform != platform.rawValue { return }
        switch event["event"] as? String {
        case "creator":
            var id = event["id"] as? String ?? ""
            if platform == .bilibili, let text = event["homepage"] as? String,
               let components = URLComponents(string: text), components.scheme == "https",
               components.host == "space.bilibili.com", components.user == nil, components.password == nil,
               components.port == nil,
               components.path.range(of: #"^/[0-9]+/?$"#, options: .regularExpression) != nil {
                id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            if resumeLocked, let creatorID, !creatorID.isEmpty, !id.isEmpty, id != creatorID {
                blocked = true
                scanComplete = false
                sawTerminal = true
                error = "继续扫描得到的作者与当前结果不一致，已停止。"
                detail = error ?? detail
                process?.terminate()
                return
            }
            if !id.isEmpty { creatorID = id }
            if let text = event["homepage"] as? String, let url = URL(string: text),
               platform.allowsNavigation(url),
               (platform != .douyin || (url.host == "www.douyin.com" && url.path == "/user/\(id)")) {
                homepageURL = url
                sourceURL = text
            }
            if let name = event["nickname"] as? String, !name.isEmpty { creatorName = name }
            if let count = jsonInt(event["awemeCount"] ?? event["postCount"]) { homepageCount = count }
        case "post":
            guard let raw = event["post"] as? [String: Any],
                  (raw["platform"] as? String).map({ $0 == platform.rawValue }) ?? true,
                  JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  var post = try? JSONDecoder().decode(CreatorPost.self, from: data),
                  !post.id.isEmpty, MediaPlatform.detect(link: post.link) == platform else { return }
            if let rawPlatform = post.platformRaw, rawPlatform != platform.rawValue { return }
            post.platformRaw = platform.rawValue
            currentRunIDs.insert(post.id)
            if let index = posts.firstIndex(where: { $0.id == post.id }) {
                posts[index] = post
                return
            }
            posts.append(post)
            if post.isVideo { selectedIDs.insert(post.id) }
            scannedCount = posts.count
        case "scan_progress":
            if let pages = jsonInt(event["pages"]) { pageCount = pageBase + pages }
            if let received = jsonInt(event["received"]) { progressReceived = received }
            scannedCount = posts.count
            if event.keys.contains("cursor") { nextCursor = jsonString(event["cursor"]) }
            if let text = event["detail"] as? String, !text.isEmpty { detail = text }
            if let flag = jsonBool(event["tainted"]) { carryPartial = flag }
        case "scan_complete":
            sawTerminal = true
            if let pages = jsonInt(event["pages"]) { pageCount = pageBase + pages }
            if let received = jsonInt(event["received"]) { progressReceived = received }
            scannedCount = posts.count
            if event.keys.contains("cursor") { nextCursor = jsonString(event["cursor"]) }
            let reason = event["reason"] as? String ?? ""
            diagnosticText = diagnosticSummary(event)
            let done = jsonBool(event["complete"]) == true && reason == "complete"
            scanComplete = done
            if let flag = jsonBool(event["tainted"]) {
                carryPartial = flag
            } else if reason == "partial" {
                carryPartial = true
            } else if reason == "complete" {
                carryPartial = false
            }
            if done {
                if recoveryRun {
                    posts.removeAll { !currentRunIDs.contains($0.id) }
                    selectedIDs.formIntersection(currentRunIDs)
                    scannedCount = posts.count
                }
                error = sessionPersistenceError
                let shared = jsonInt(event["coauthoredCount"]) ?? posts.filter { $0.isCoauthored == true }.count
                detail = shared > 0 ? "已全部采完：本人发布 \(posts.count - shared) 条，参与共创 \(shared) 条，共 \(posts.count) 条。" : "已全部采完"
                nextCursor = nil
            } else if reason == "share_resolved", platform == .wechat, currentRunIDs.count == 1 {
                shareResolved = true
                error = sessionPersistenceError
                diagnosticText = ""
                detail = "已解析这条分享的视频，可选择保存；这不代表作者全部作品。"
                nextCursor = nil
            } else if reason == "login_required" {
                // An API login challenge is not evidence that the user's live
                // webpage is logged out. Preserve it for verification/recovery.
                needsLogin = true
                nextCursor = nil
                error = sessionPersistenceError
                let home = jsonInt(event["awemeCount"]) ?? homepageCount
                let prefix = home.map { "主页显示 \($0) 条，" } ?? ""
                detail = platform == .wechat
                    ? ((event["detail"] as? String) ?? "元宝解析接口尚未验证登录。请打开内置元宝窗口检查后重试；现有网页登录和已采作品保留。")
                    : "\(prefix)当前获取 \(posts.count) 条（\(videoPosts.count) 条视频）。\(platform.title)接口要求登录或验证，请打开内置网页检查后补采；现有网页登录和作品保留。"
            } else if reason == "limit" {
                error = nil
                detail = "仅采到部分：本批达到页数上限，可继续扫描。"
            } else if reason == "cancelled" {
                scanCancelled = true
                detail = "已取消扫描，已保留已采结果"
                error = nil
            } else if reason == "count_mismatch" {
                error = countMismatchMessage(event)
                detail = error ?? detail
            } else {
                error = (event["message"] as? String) ?? (event["detail"] as? String) ?? reasonMessage(reason)
                if pageBase > 0, let failedPage = (event["diagnostic"] as? [String: Any])?["page"] as? Int {
                    error = "累计第 \(pageBase + failedPage) 页（本轮第 \(failedPage) 页）。" + (error ?? "")
                }
                detail = error ?? detail
            }
        case "error":
            sawTerminal = true
            scanComplete = false
            shareResolved = false
            error = event["message"] as? String ?? "扫描失败。"
            diagnosticText = diagnosticSummary(event)
            detail = error ?? detail
        case "cancelled":
            scanCancelled = true
            sawTerminal = true
            scanComplete = false
            cancelRequested = true
            error = nil
            detail = "已取消扫描，已保留已采结果"
        default:
            break
        }
    }

    func finish(token: UUID, code: Int32) {
        guard token == generation else { return }
        isScanning = false
        process = nil
        deleteSeenFile()
        if cancelRequested {
            scanComplete = false
            error = nil
            detail = "已取消扫描，已保留已采结果"
            cancelRequested = false
            return
        }
        // 非零退出，或进程结束时没有 scan_complete / error / cancelled，都不能留下“已全部采完”。
        if code != 0 || !sawTerminal {
            let claimedDone = scanComplete || shareResolved || detail == "已全部采完"
            scanComplete = false
            if !sawTerminal && error == nil {
                error = "采集组件已退出（退出码 \(code)），没有返回完成或错误回执。已保留 \(posts.count) 条作品；请复制问题详情后重试。"
                diagnosticText = "阶段：采集组件运行\n问题：missing_terminal_event\n退出码：\(code)\n已保留：\(posts.count) 条"
                detail = error ?? detail
            } else if code != 0 && claimedDone {
                shareResolved = false
                error = "采集组件报告完成后异常退出（退出码 \(code)），本次不能确认采集完整。已采作品保留。"
                detail = error ?? detail
            }
        }
    }

    private func diagnosticSummary(_ event: [String: Any]) -> String {
        guard (event["complete"] as? Bool) != true else { return "" }
        let data = event["diagnostic"] as? [String: Any] ?? [:]
        var lines = ["平台：\(platform.title)", "问题：\(data["code"] ?? event["reason"] ?? "worker_error")"]
        for (key, label) in [("stage", "阶段"), ("page", "本轮失败页"), ("httpStatus", "HTTP 状态"), ("apiStatus", "平台状态码"), ("responseBytes", "响应字节"), ("attempts", "尝试次数"), ("errorType", "异常类型"), ("endpoint", "接口路径")] {
            if let value = data[key] { lines.append("\(label)：\(value)") }
        }
        if let fields = data["missingFields"] as? [String] { lines.append("缺少字段：" + fields.joined(separator: ", ")) }
        if let attached = data["sessionAttached"] as? Bool { lines.append("采集登录：" + (attached ? "已携带" : "未携带")) }
        if let message = event["message"] as? String ?? event["detail"] as? String { lines.append(message) }
        lines.append("已保留：\(posts.count) 条作品")
        return lines.joined(separator: "\n")
    }

    private func reasonMessage(_ reason: String) -> String {
        switch reason {
        case "duplicate_cursor":
            return "翻页游标重复，已停止并保留已采结果。"
        case "restricted":
            return "\(platform.title)限制了这次访问，已保留已采结果，不能视为全部采完。"
        case "empty":
            return "没有返回作品，不能视为已全部采完。"
        case "bad_json":
            return "平台响应缺少有效作品或分页字段。组件未提供具体字段名，请复制问题详情；已采作品保留。"
        case "http":
            return "作品列表请求失败，已保留已采结果。"
        case "timeout":
            return "请求超时，已保留已采结果。"
        case "limit":
            return "仅采到部分：本批达到页数上限，可继续扫描。"
        case "cancelled":
            return "已取消扫描，已保留已采结果。"
        case "count_mismatch":
            return "仅采到一部分，不能视为全部采完。"
        case "partial":
            return platform == .douyin ? "部分作品缺少可解析字段或作者标识不匹配，已跳过这些条目；已采作品保留，本次不标为全部采完。" : "已采集当前网页加载的视频。可在内置网页继续浏览后再次采集；不能视为作者全部作品。"
        case "web_capture_partial":
            return "已采集当前网页加载的视频。请在内置网页继续打开或滚动，再采集；不能视为作者全部作品。"
        case "browser_required":
            return "请打开内置官方网页，登录并实际加载视频，再点「采集网页视频」。"
        case "unknown_count":
            return "主页没有给出可靠作品数，已保留已采结果，不能视为全部采完。"
        default:
            return "采集停止（问题代码：\(reason.isEmpty ? "unknown" : reason)）。组件未提供具体原因，请复制问题详情；已采作品保留。"
        }
    }

    private func countMismatchMessage(_ event: [String: Any]) -> String {
        let listed = jsonInt(event["primaryCount"]) ?? jsonInt(event["listedCount"]) ?? posts.count
        let home = jsonInt(event["awemeCount"]) ?? homepageCount
        if let home {
            let gap = jsonInt(event["gap"]) ?? (home - listed)
            let shared = jsonInt(event["coauthoredCount"]) ?? 0
            return "数量尚未对齐：主页计数 \(home)，本人发布已列 \(listed)，差额 \(gap)；另有共创 \(shared) 条。可能有未公开作品或采集期间数量变化，平台未提供具体原因。已采作品保留。"
        }
        return "仅采到一部分：主页没有给出作品数，已列 \(listed)。不能视为全部采完。"
    }

    private enum SeenFileResult {
        case empty
        case ready(URL)
        case invalid
    }

    /// 每个续扫任务一个私有临时文件，内容只是字符串 ID 数组。不把 ID 拼进 argv。
    private func makeSeenFile() -> SeenFileResult {
        let ids = (recoveryRun ? Array(currentRunIDs) : posts.map(\.id)).filter { !$0.isEmpty }
        if ids.isEmpty { return .empty }
        if ids.contains(where: { platform == .douyin ? !decimalID($0) : ($0.isEmpty || $0.count > 256 || $0.contains("\n")) }) { return .invalid }
        let unique = Array(Set(ids)).sorted()
        let shared = posts.filter { $0.isCoauthored == true && unique.contains($0.id) }.map(\.id).sorted()
        let payload: Any = platform == .douyin && !shared.isEmpty ? ["version": 2, "ids": unique, "coauthoredIDs": shared] : unique
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shiying-seen-\(UUID().uuidString).json")
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return .invalid
        }
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return .invalid
        }
        return .ready(url)
    }

    private func deleteSeenFile() {
        guard let seenIDsFile else { return }
        try? FileManager.default.removeItem(at: seenIDsFile)
        self.seenIDsFile = nil
    }

    private func decimalID(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 24 else { return false }
        return text.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    private func jsonBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// JSON 的 0/1 也会桥接成 Bool，不能用 `is Bool` 判断，否则页数 1 会被丢掉。
    private func jsonInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private func jsonString(_ value: Any?) -> String? {
        if value == nil || value is NSNull { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if value is Bool { return nil }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
