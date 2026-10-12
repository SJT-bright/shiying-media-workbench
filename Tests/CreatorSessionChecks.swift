import Foundation

@main struct CreatorSessionChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ name: String, _ ok: Bool) {
            guard ok else { fatalError("FAIL \(name)") }
            checks += 1; print("PASS \(name)")
        }
        let id = "MS4wLjABAAAA_SYNTHETIC_DOUYIN_AUTHOR_0001"
        let home = "https://www.douyin.com/user/\(id)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shiying-creator-session-\(UUID().uuidString)", isDirectory: true)
        CreatorStore.sessionFileOverride = root.appendingPathComponent("creator-session.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreatorStore()
        check("fresh store has no saved login", !store.hasSession)
        let auth = HTTPCookie(properties: [.name: "sessionid", .value: "SYNTHETIC_ONLY", .domain: ".douyin.com", .path: "/"])!
        let emptyFlag = HTTPCookie(properties: [.name: "douyin.com", .value: "", .domain: ".douyin.com", .path: "/"])!
        if case .success(let exported) = CreatorStore.sessionFromCookies([auth, emptyFlag], platform: .douyin) {
            check("empty site flag must not reject authenticated login", exported != nil && CreatorStore.acceptedSession(exported!) != nil)
        } else { fatalError("valid login rejected by empty optional cookie") }
        if case .success(let exported) = CreatorStore.sessionFromCookies([emptyFlag], platform: .douyin) {
            check("empty non-authentication cookie does not invent login", exported == nil)
        } else { fatalError("guest cookie should report no session") }
        let emptyAuth = HTTPCookie(properties: [.name: "sessionid", .value: "", .domain: ".douyin.com", .path: "/"])!
        if case .success(let exported) = CreatorStore.sessionFromCookies([emptyAuth], platform: .douyin) {
            check("empty authentication cookie is not accepted as login", exported == nil)
        } else { fatalError("empty auth should report no session") }
        func send(_ event: [String: Any]) { store.handle(event, token: store.scanGeneration) }
        send(["event": "creator", "id": id, "nickname": "合成作者", "homepage": home, "awemeCount": 19])
        for i in 0..<4 {
            let pid = String(7000000000000000000 + i)
            send(["event": "post", "post": ["id": pid, "link": "https://www.douyin.com/video/\(pid)",
                                             "title": "旧作品", "author": "合成作者", "isVideo": true]])
        }
        send(["event": "scan_complete", "complete": false, "reason": "login_required", "pages": 1,
              "received": 4, "awemeCount": 19, "listedCount": 4, "gap": 15])
        check("login restriction keeps four results", store.needsLogin && store.posts.count == 4 && !store.scanComplete)
        check("actionable counts without generic error", store.error == nil && store.detail.contains("19") && store.detail.contains("4 条"))
        store.urlText = "另一个作者的编辑草稿"
        check("source stays attached to scanned author", store.sourceURL == home && store.homepageURL?.absoluteString == home)
        store.toggleSelection("7000000000000000000")
        store.filter.likesAbove = 10
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/fixtures/creator_session_worker.py")
        CreatorStore.workerOverrideURL = fixture
        let payload = try JSONSerialization.data(withJSONObject: [["name": "sessionid", "value": "SYNTHETIC_ONLY",
                                                                   "domain": ".douyin.com", "path": "/"]])
        store.useSession(payload)
        check("recovery preserves results while busy", store.isScanning && store.posts.count == 4 && store.hasSession)
        check("recovery uses original homepage and filter", store.urlText == home && store.filter.likesAbove == 10)
        let deadline = Date().addingTimeInterval(5)
        while store.isScanning && Date() < deadline { try await Task.sleep(nanoseconds: 20000000) }
        check("session through stdin finishes nineteen", store.scanComplete && store.posts.count == 19 && !store.needsLogin)
        check("duplicates refreshed without restoring deselection", store.posts.first?.title == "更新作品0" && !store.selectedIDs.contains("7000000000000000000"))
        check("new videos selected once", store.selectedIDs.count == 18)
        send(["event":"scan_complete", "complete":false, "reason":"bad_json", "pages":1, "cursor":"50",
              "message":"第 2 页：接口只返回状态码 0，没有作品列表。", "diagnostic":["code":"missing_posts", "page":2,
              "httpStatus":200, "apiStatus":0, "sessionAttached":true, "missingFields":["aweme_list"], "attempts":3]])
        check("exact worker cause reaches UI and copied diagnostics", store.error?.contains("状态码 0") == true
              && store.diagnosticText.contains("aweme_list") && store.diagnosticText.contains("HTTP 状态：200") && store.nextCursor == "50")
        let retained = try Data(contentsOf: CreatorStore.sessionFileURL())
        send(["event":"scan_complete", "complete":false, "reason":"login_required", "pages":1])
        check("API login challenge preserves live session and saved credential", store.hasSession && store.needsLogin
              && (try? Data(contentsOf: CreatorStore.sessionFileURL())) == retained)
        store.clearSession()
        check("clear login state", !store.hasSession)
        let wrong = try JSONSerialization.data(withJSONObject: [["name": "sessionid", "value": "WRONG_AUTHOR",
                                                                "domain": ".douyin.com", "path": "/"]])
        store.useSession(wrong)
        while store.isScanning && Date() < deadline.addingTimeInterval(5) { try await Task.sleep(nanoseconds: 20000000) }
        check("author mismatch stops and keeps source/results", !store.scanComplete && store.error?.contains("作者") == true
              && store.posts.count == 19 && store.sourceURL == home)
        store.shutdown()
        check("shutdown keeps saved login", store.hasSession && !store.isScanning)
        let restored = CreatorStore()
        check("reopen restores login", restored.hasSession)
        restored.clearSession()
        check("clear removes saved login", !restored.hasSession
              && !FileManager.default.fileExists(atPath: CreatorStore.sessionFileOverride!.path))
        func platformSession(_ platform: MediaPlatform, domain: String, name: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 1, "platform": platform.rawValue,
                "cookies": [["name": name, "value": "SYNTHETIC_ONLY", "domain": domain, "path": "/"]]])
        }
        let bili = try platformSession(.bilibili, domain: ".bilibili.com", name: "SESSDATA")
        let xhs = try platformSession(.xiaohongshu, domain: ".xiaohongshu.com", name: "web_session")
        check("four distinct browser partitions", Set(MediaPlatform.allCases.map(\.websiteIdentifier)).count == 4)
        check("legacy Douyin filename remains", CreatorStore.sessionFileURL().lastPathComponent == "creator-session.json")
        check("platform login rejects another platform", CreatorStore.acceptedSession(bili, platform: .douyin) == nil)
        check("Bilibili accepts only platform credentials", CreatorStore.acceptedSession(bili, platform: .bilibili) != nil)
        let mixed = try platformSession(.bilibili, domain: ".douyin.com", name: "SESSDATA")
        check("mixed domain rejected", CreatorStore.acceptedSession(mixed, platform: .bilibili) == nil)
        let previousToken = store.scanGeneration
        store.selectPlatform(.bilibili)
        check("switch removes previous author result and source", store.posts.isEmpty && store.sourceURL.isEmpty && store.homepageURL == nil && !store.hasSession && store.filter == CreatorFilter())
        store.handle(["event": "post", "post": ["id": "late", "link": home, "title": "旧平台", "author": "旧平台", "isVideo": true]], token: previousToken)
        check("late prior platform result rejected", store.posts.isEmpty)
        store.useSession(bili)
        check("Bilibili login persists without auto scan", store.hasSession && !store.isScanning)
        let biliURL = CreatorStore.sessionFileURL(platform: .bilibili)
        let perms = try FileManager.default.attributesOfItem(atPath: biliURL.path)[.posixPermissions] as? NSNumber
        check("credentials file is private from creation", perms?.intValue == 0o600)
        store.selectPlatform(.xiaohongshu); store.useSession(xhs)
        store.selectPlatform(.bilibili)
        check("platform switch restores matching login", store.hasSession && store.platform == .bilibili)
        store.clearSession()
        check("clear one platform retains other login", CreatorStore.sessionForWorker(platform: .bilibili) == nil && CreatorStore.sessionForWorker(platform: .xiaohongshu) != nil)
        let wxLink = "https://channels.weixin.qq.com/platform#shiying-capture-web-fixture"
        let captured = try JSONSerialization.data(withJSONObject: ["version": 1, "platform": "wechat", "cookies": [],
            "captureSource": "https://channels.weixin.qq.com/platform", "capturedPosts": [["id": "web-fixture", "link": wxLink,
                "title": "合成媒体", "author": "", "mediaURL": "https://finder.video.qq.com/fixture.mp4", "isVideo": true]]])
        check("captured actual-source metadata accepted", CreatorStore.acceptedSession(captured, platform: .wechat) != nil)
        check("unrelated media host and blob rejected", !PlatformWebCapture.acceptedMediaURL("https://example.com/media.mp4", platform: .wechat) && !PlatformWebCapture.acceptedMediaURL("blob:https://channels.weixin.qq.com/fixture", platform: .wechat))
        check("spoof platform host rejected", MediaPlatform.detect(link: "https://bilibili.com.evil.example/video/BV123") == nil)
        let blockedRoot = root.appendingPathComponent("blocked-file")
        try Data("block".utf8).write(to: blockedRoot)
        CreatorStore.sessionFileOverride = blockedRoot.appendingPathComponent("creator-session.json")
        let failedSave = CreatorStore()
        failedSave.useSession(payload)
        check("failed persistence stays visible without exposing credentials", failedSave.hasSession && failedSave.error?.contains("写入本机失败") == true && failedSave.error?.contains("SYNTHETIC_ONLY") == false)
        CreatorStore.sessionFileOverride = root.appendingPathComponent("creator-session.json")
        let noHome = CreatorStore(); noHome.selectPlatform(.bilibili)
        noHome.handle(["event": "creator", "id": "1", "homepage": "https://space.bilibili.com/1", "nickname": "B站测试"], token: noHome.scanGeneration)
        check("Bilibili source binding accepts official homepage", noHome.sourceURL == "https://space.bilibili.com/1")
        noHome.handle(["event": "post", "post": ["id": "bad", "link": home, "title": "错平台", "author": "", "isVideo": true, "platform": "douyin"]], token: noHome.scanGeneration)
        check("worker wrong-platform post rejected", noHome.posts.isEmpty)
        check("shared text detects Bilibili login route", MediaPlatform.detect(link: "分享作品 https://www.bilibili.com/video/BV1xx411c7mD 给你") == .bilibili)
        check("alternate xhs shortlink host", MediaPlatform.detect(link: "https://www.xhslink.com/a/test") == .xiaohongshu)
        let badVersion = try JSONSerialization.data(withJSONObject: ["version": true, "platform": "bilibili", "cookies": [["name": "SESSDATA", "value": "fixture", "domain": ".bilibili.com", "path": "/"]]])
        check("boolean envelope version rejected", CreatorStore.acceptedSession(badVersion, platform: .bilibili) == nil)
        let badControl = try JSONSerialization.data(withJSONObject: ["version": 1, "platform": "bilibili", "cookies": [["name": "SESSDATA", "value": "fixture\nheader", "domain": ".bilibili.com", "path": "/"]]])
        check("cookie control characters rejected", CreatorStore.acceptedSession(badControl, platform: .bilibili) == nil)
        let expired = try JSONSerialization.data(withJSONObject: ["version": 1, "platform": "bilibili", "cookies": [["name": "SESSDATA", "value": "fixture", "domain": ".bilibili.com", "path": "/", "expires": 1]]])
        check("expired exported cookie rejected", CreatorStore.acceptedSession(expired, platform: .bilibili) == nil)
        let visibleBili = try JSONSerialization.data(withJSONObject: ["version": 1, "platform": "bilibili", "cookies": [], "captureSource": "https://space.bilibili.com/1", "capturedPosts": [["id": "BV1xx411c7mD", "link": "https://www.bilibili.com/video/BV1xx411c7mD", "title": "已加载作品", "author": "", "isVideo": true]]])
        check("Bilibili visible links need no speculative media URL", CreatorStore.acceptedSession(visibleBili, platform: .bilibili) != nil)
        noHome.handle(["event": "post", "post": ["id": "bad2", "link": home, "title": "错网址", "author": "", "isVideo": true]], token: noHome.scanGeneration)
        check("wrong platform official link rejected even without platform field", noHome.posts.isEmpty)
        noHome.handle(["event": "scan_complete", "complete": false, "reason": "partial"], token: noHome.scanGeneration)
        check("visible scan clearly says current loaded range", noHome.detail.contains("当前网页") && !noHome.scanComplete)
        let yuanbaoRows: [[String: Any]] = [["name": "hy_user", "value": "SYNTHETIC_USER", "domain": ".yuanbao.tencent.com", "path": "/"], ["name": "hy_token", "value": "SYNTHETIC_TOKEN", "domain": ".yuanbao.tencent.com", "path": "/"]]
        let yuanbao = try JSONSerialization.data(withJSONObject: ["version": 1, "platform": "wechat", "cookies": yuanbaoRows])
        check("Yuanbao authenticated pair accepted for Channels parsing", CreatorStore.acceptedSession(yuanbao, platform: .wechat) != nil)
        let tokenOnly = try JSONSerialization.data(withJSONObject: ["version": 1, "platform": "wechat", "cookies": [yuanbaoRows[1]]])
        check("Yuanbao requires user and token pair", CreatorStore.acceptedSession(tokenOnly, platform: .wechat) == nil)
        var broadRows = yuanbaoRows; broadRows[0]["domain"] = ".tencent.com"
        let broad = try JSONSerialization.data(withJSONObject: ["version": 1, "platform": "wechat", "cookies": broadRows])
        check("raw unscoped Tencent session rejected", CreatorStore.acceptedSession(broad, platform: .wechat) == nil)
        let parentUser = HTTPCookie(properties: [.name: "hy_user", .value: "SYNTHETIC_USER", .domain: ".tencent.com", .path: "/"])!
        let parentToken = HTTPCookie(properties: [.name: "hy_token", .value: "SYNTHETIC_TOKEN", .domain: ".tencent.com", .path: "/"])!
        let unrelatedTencent = HTTPCookie(properties: [.name: "unrelated_session", .value: "SYNTHETIC_OTHER", .domain: ".tencent.com", .path: "/"])!
        let parentRows = CreatorStore.sessionCookieObjects([parentUser, parentToken, unrelatedTencent], platform: .wechat)
        check("own Yuanbao parent credentials are restricted to parser host", parentRows.count == 2 && parentRows.allSatisfy { $0["domain"] as? String == "yuanbao.tencent.com" })
        if case .success(let exported) = CreatorStore.sessionFromCookies([parentUser, parentToken, unrelatedTencent], platform: .wechat) {
            check("current Yuanbao login exports a valid authenticated session", exported != nil && CreatorStore.acceptedSession(exported!, platform: .wechat) != nil)
        } else { fatalError("own Yuanbao parent credentials rejected") }
        check("Yuanbao normalization cannot export into Douyin", CreatorStore.sessionCookieObjects([parentUser, parentToken], platform: .douyin).isEmpty)
        check("Tencent parent remains outside media and navigation hosts", !MediaPlatform.wechat.acceptsCookieDomain(".tencent.com") && !MediaPlatform.wechat.allowsNavigation(URL(string: "https://tencent.com/")!))
        check("Yuanbao login URL explicitly allowed", MediaPlatform.wechat.allowsNavigation(MediaPlatform.wechatParserLoginURL))
        check("Yuanbao login page never identified as media link", MediaPlatform.detect(link: MediaPlatform.wechatParserLoginURL.absoluteString) == nil)
        check("unrelated Tencent app rejected in login navigation", !MediaPlatform.wechat.allowsNavigation(URL(string: "https://docs.qq.com/")!))
        let parserStore = CreatorStore(); parserStore.selectPlatform(.wechat); parserStore.useSession(yuanbao)
        check("Yuanbao login remains idle until share input", parserStore.hasSession && !parserStore.isScanning && parserStore.detail.contains("元宝"))
        check("Wechat share download retrieves same app parser session", CreatorStore.sessionForDownload(link: "视频号分享 https://weixin.qq.com/sph/SYNTHETIC_ONLY") == yuanbao)
        CreatorStore.sessionFileOverride = root.appendingPathComponent("auto/creator-session.json")
        CreatorStore.sessionCookieReaderOverride = { completion in completion([auth, emptyFlag]) }
        let automatic = CreatorStore(); automatic.urlText = home
        automatic.scan()
        check("scan automatically uses logged-in WebKit cookies without save button", automatic.hasSession && automatic.isScanning)
        let automaticDeadline = Date().addingTimeInterval(5)
        while automatic.isScanning && Date() < automaticDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        check("automatic handoff completes authenticated scan", automatic.scanComplete && automatic.posts.count == 19)
        var pendingCookieRead: (([HTTPCookie]) -> Void)?
        CreatorStore.sessionCookieReaderOverride = { pendingCookieRead = $0 }
        automatic.scan(); automatic.cancel()
        pendingCookieRead?([auth])
        check("cancelled asynchronous cookie callback cannot restart scan", !automatic.isScanning && automatic.posts.count == 19)
        CreatorStore.sessionCookieReaderOverride = { $0([]) }
        let cold = CreatorStore(); cold.urlText = home
        cold.scan()
        check("empty WebKit read falls back to saved authenticated session", cold.hasSession && cold.isScanning)
        let coldDeadline = Date().addingTimeInterval(5)
        while cold.isScanning && Date() < coldDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        check("saved session fallback completes without reopening login page", cold.scanComplete && cold.posts.count == 19)

        CreatorStore.sessionCookieReaderOverride = { $0([parentUser, parentToken, unrelatedTencent]) }
        let channelsAuto = CreatorStore(); channelsAuto.selectPlatform(.wechat)
        channelsAuto.urlText = "https://weixin.qq.com/sph/SYNTHETIC_ONLY"
        channelsAuto.scan()
        check("Channels parsing automatically synchronizes its own Yuanbao partition", channelsAuto.hasSession && channelsAuto.isScanning && CreatorStore.sessionForWorker(platform: .wechat) != nil)
        let channelsDeadline = Date().addingTimeInterval(5)
        while channelsAuto.isScanning && Date() < channelsDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        check("automatic Channels handoff receives one share without claiming archive", channelsAuto.posts.count == 1 && channelsAuto.shareResolved && !channelsAuto.scanComplete && channelsAuto.error == nil)

        let missingTerminal = CreatorStore()
        let terminalToken = missingTerminal.scanGeneration
        missingTerminal.handle(["event": "post", "post": ["id": "7000000000000000001", "link": "https://www.douyin.com/video/7000000000000000001", "title": "保留作品", "author": "合成作者", "isVideo": true]], token: terminalToken)
        missingTerminal.finish(token: terminalToken, code: 0)
        check("zero exit without terminal receipt cannot claim completion", !missingTerminal.scanComplete && missingTerminal.posts.count == 1 && missingTerminal.diagnosticText.contains("missing_terminal_event"))
        check("missing receipt names process exit and retained count", missingTerminal.error?.contains("退出码 0") == true && missingTerminal.error?.contains("1 条") == true)
        missingTerminal.handle(["event": "scan_complete", "complete": true, "reason": "complete"], token: terminalToken)
        missingTerminal.finish(token: terminalToken, code: 7)
        check("abnormal exit after completion claim revokes completion", !missingTerminal.scanComplete && missingTerminal.posts.count == 1 && missingTerminal.error?.contains("退出码 7") == true)
        CreatorStore.sessionCookieReaderOverride = nil
        print("CreatorSessionChecks: \(checks) passed")
    }
}
