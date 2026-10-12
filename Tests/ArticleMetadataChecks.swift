import Foundation
import CryptoKit

/// Synthetic metadata regression. Compile with the app sources, same style as ArticleChecks.
/// Does not load a public-account page and does not read the real library.
@main struct ArticleMetadataChecks {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ label: String, _ value: Bool) {
            precondition(value, "FAIL " + label)
            checks += 1
            print("PASS " + label)
        }
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let later = Date(timeIntervalSince1970: 1_700_000_200)
        let link = "https://mp.weixin.qq.com/s/MetaArticle"
        func historicalNames(_ stats: ArticleStatistics) -> Set<String> { Set(stats.historical ?? []) }

        check("public zero stays zero", ArticleStatistics.publicValue("0") == "0")
        check("trimmed public zero stays zero", ArticleStatistics.publicValue(" 0 ") == "0")
        check("public 1.5万+ is kept", ArticleStatistics.publicValue(" 1.5万+ ") == "1.5万+")
        check("10万+ is kept", ArticleStatistics.publicValue("10万+") == "10万+")
        check("unpublished text is nil", ArticleStatistics.publicValue("未公开") == nil)
        check("empty count is nil", ArticleStatistics.publicValue("") == nil)
        check("nil count is nil", ArticleStatistics.publicValue(nil) == nil)

        let fifty = String(repeating: "文", count: 50)
        let fiftyOne = fifty + "字"
        check("exactly 50 characters have no ellipsis", ArticleCardContent.snippet(fifty) == fifty)
        check("51st character adds three dots", ArticleCardContent.snippet(fiftyOne) == fifty + "...")
        let emoji = String(repeating: "😀", count: 50)
        check("50 emoji characters stay intact", ArticleCardContent.snippet(emoji) == emoji)
        check("51st emoji is not split", ArticleCardContent.snippet(emoji + "文") == emoji + "...")
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        let families = String(repeating: family, count: 51)
        check("ZWJ family is truncated on character boundaries", ArticleCardContent.snippet(families) == String(repeating: family, count: 50) + "...")
        let accent = "e\u{0301}"
        check("combining character counts as one", ArticleCardContent.snippet(String(repeating: accent, count: 51)) == String(repeating: accent, count: 50) + "...")
        check("whitespace runs collapse before the 50-character cut", ArticleCardContent.snippet("文   文") == "文 文")
        var excerptRecord = ArticleRecord(link: link)
        excerptRecord.excerpt = fiftyOne
        check("stored excerpt uses the 50-character snippet", ArticleCardContent.storedExcerpt(excerptRecord) == fifty + "...")
        check("missing excerpt without a file is the waiting placeholder", ArticleCardContent.storedExcerpt(ArticleRecord(link: link)) == "等待读取文章正文")

        check("qpic cover is approved", ArticleCardContent.approvedCover("https://mmbiz.qpic.cn/mmbiz_png/a")?.host == "mmbiz.qpic.cn")
        check("http qpic cover is upgraded to https", ArticleCardContent.approvedCover("http://thirdwx.qpic.cn/a.png")?.scheme == "https")
        check("qlogo cover is approved", ArticleCardContent.approvedCover("https://thirdwx.qlogo.cn/mmopen/a") != nil)
        check("foreign cover is rejected", ArticleCardContent.approvedCover("https://evil.example/a.png") == nil)
        check("suffix lookalike cover is rejected", ArticleCardContent.approvedCover("https://mmbiz.qpic.cn.evil.example/a.png") == nil)
        check("cover with userinfo is rejected", ArticleCardContent.approvedCover("https://user:secret@mmbiz.qpic.cn/a.png") == nil)
        check("cover on an unapproved port is rejected", ArticleCardContent.approvedCover("https://mmbiz.qpic.cn:444/a.png") == nil)
        check("nil cover is rejected", ArticleCardContent.approvedCover(nil) == nil)

        let fileRoot = FileManager.default.temporaryDirectory.appendingPathComponent("shiying-article-metadata-files-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileRoot) }
        let articleDir = fileRoot.appendingPathComponent("文章目录")
        let imageDir = articleDir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==")!
        let coverFile = imageDir.appendingPathComponent("cover.png")
        try png.write(to: coverFile)
        let outside = fileRoot.appendingPathComponent("outside.png")
        try png.write(to: outside)
        let source: [String: Any] = ["cover": ["path": "images/cover.png", "bytes": png.count, "sha256": "local", "source": "https://mmbiz.qpic.cn/a.png"]]
        try JSONSerialization.data(withJSONObject: source).write(to: articleDir.appendingPathComponent("来源.json"))
        var local = ArticleRecord(link: link)
        local.path = articleDir.path
        check("manifest cover stays inside the article directory", ArticleCardContent.localCover(local)?.standardizedFileURL.path == coverFile.standardizedFileURL.path)
        local.coverPath = coverFile.path
        check("in-directory coverPath is readable", ArticleCardContent.localCover(local)?.standardizedFileURL.path == coverFile.standardizedFileURL.path)
        local.coverPath = outside.path
        check("external coverPath falls back to the validated manifest", ArticleCardContent.localCover(local)?.path == coverFile.path)
        local.coverPath = nil
        let escaped: [String: Any] = ["cover": ["path": "../outside.png"]]
        try JSONSerialization.data(withJSONObject: escaped).write(to: articleDir.appendingPathComponent("来源.json"))
        check("manifest path cannot escape the article directory", ArticleCardContent.localCover(local) == nil)
        try FileManager.default.createSymbolicLink(at: imageDir.appendingPathComponent("linked.png"), withDestinationURL: outside)
        let linked: [String: Any] = ["cover": ["path": "images/linked.png"]]
        try JSONSerialization.data(withJSONObject: linked).write(to: articleDir.appendingPathComponent("来源.json"))
        check("symlinked cover cannot leave the article directory", ArticleCardContent.localCover(local) == nil)

        let oldJSON = """
        [{"id":"\(UUID().uuidString)","link":"https://mp.weixin.qq.com/s/OldArticle","title":"旧文章","account":"旧公众号","author":"","published":"","imageCount":0,"characters":0,"bytes":0,"status":"待保存","date":0}]
        """
        let oldRecords = try JSONDecoder().decode([ArticleRecord].self, from: Data(oldJSON.utf8))
        check("old record omits excerpt", oldRecords[0].excerpt == nil)
        check("old record omits coverURL", oldRecords[0].coverURL == nil)
        check("old record omits coverPath", oldRecords[0].coverPath == nil)
        check("old record omits statistics", oldRecords[0].statistics == nil)
        let oldStats = """
        [{"id":"\(UUID().uuidString)","link":"https://mp.weixin.qq.com/s/OldStats","title":"旧统计","account":"旧公众号","author":"","published":"","imageCount":0,"characters":0,"bytes":0,"status":"已保存","date":0,"statistics":{"read":"1.5万+","like":"0"}}]
        """
        let statsRecords = try JSONDecoder().decode([ArticleRecord].self, from: Data(oldStats.utf8))
        check("old statistics keep 1.5万+", statsRecords[0].statistics?.read == "1.5万+")
        check("old statistics keep real zero", statsRecords[0].statistics?.like == "0")
        check("missing watching stays nil", statsRecords[0].statistics?.watching == nil)
        check("missing comments stay nil", statsRecords[0].statistics?.comments == nil)
        check("missing historical stays nil", statsRecords[0].statistics?.historical == nil)
        check("missing statistics error stays nil", statsRecords[0].statistics?.error == nil)
        let repoDir = fileRoot.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let repo = HistoryRepository<ArticleRecord>(fileURL: repoDir.appendingPathComponent("article-library.json"))
        var roundTrip = statsRecords[0]
        roundTrip.statistics?.historical = ["read"]
        try repo.save([roundTrip])
        let stored = try repo.load()
        check("historical round-trips beside the real zero", stored[0].statistics?.historical == ["read"] && stored[0].statistics?.like == "0" && stored[0].statistics?.read == "1.5万+")

        let previous = ArticleStatistics(read: "1.5万+", like: "0", watching: nil, comments: "8", checkedAt: oldDate, error: "旧错误", historical: nil)
        let successPayload: [String: Any] = ["statistics": ["like": "1.5万+", "read": NSNull(), "watching": "0"]]
        let merged = ArticleMetadataRules.successStatistics(successPayload, previous: previous, checkedAt: now)!
        check("missing read keeps the previous 1.5万+", merged.read == "1.5万+")
        check("refreshed like replaces the old value", merged.like == "1.5万+")
        check("explicit zero is stored for watching", merged.watching == "0")
        check("omitted comments keep the previous count", merged.comments == "8")
        check("only missing previous counts are historical", historicalNames(merged) == ["read", "comments"])
        check("successful partial check explains historical values", merged.error != nil && merged.error != previous.error)
        check("successful check uses the injected date", merged.checkedAt == now)
        let created = ArticleMetadataRules.successStatistics(["statistics": ["read": "0", "like": "1.5万+"]], previous: nil, checkedAt: now)!
        check("new zero is not invented for absent fields", created.read == "0" && created.like == "1.5万+" && created.watching == nil && created.comments == nil)
        check("complete new counts have no historical mark", historicalNames(created).isEmpty)
        let failed = ArticleMetadataRules.failureStatistics(previous, message: "网页验证", checkedAt: now)
        check("failure keeps 1.5万+", failed.read == "1.5万+")
        check("failure keeps the real zero", failed.like == "0")
        check("failure does not invent watching", failed.watching == nil)
        check("failure keeps comments", failed.comments == "8")
        check("failure marks every retained count historical", historicalNames(failed) == ["read", "like", "comments"])
        check("failure records its message", failed.error == "网页验证")
        check("failure uses the injected date", failed.checkedAt == now)
        let failedEmpty = ArticleMetadataRules.failureStatistics(nil, message: "没有旧值", checkedAt: now)
        check("failure without previous values does not invent zero", failedEmpty.read == nil && failedEmpty.like == nil && failedEmpty.watching == nil && failedEmpty.comments == nil && historicalNames(failedEmpty).isEmpty)

        let root = fileRoot.appendingPathComponent("store-root")
        ArticleStore.dataRootOverride = root
        let suite = ArticleStore.testPreferencesSuite(root: root)
        defer {
            ArticleStore.dataRootOverride = nil
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let savedDir = root.appendingPathComponent("saved-article")
        try FileManager.default.createDirectory(at: savedDir, withIntermediateDirectories: true)
        let articleHTML = "<!doctype html><html><body><p>原文正文不改 \(family)</p></body></html>"
        let articleFile = savedDir.appendingPathComponent("文章.html")
        try articleHTML.write(to: articleFile, atomically: true, encoding: .utf8)
        let articleDigest = SHA256.hash(data: Data(articleHTML.utf8))
        var saved = ArticleRecord(link: link)
        saved.title = "已保存文章"
        saved.account = "测试公众号"
        saved.status = .saved
        saved.path = savedDir.path
        saved.excerpt = fiftyOne
        saved.coverURL = "https://mmbiz.qpic.cn/mmbiz_png/meta"
        saved.statistics = ArticleStatistics(read: "1.5万+", like: "0", watching: nil, comments: nil, checkedAt: oldDate, error: nil, historical: nil)
        let library = root.appendingPathComponent("articles/article-library.json")
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([saved])) as! [[String: Any]]
        var statsObject = encoded[0]["statistics"] as! [String: Any]
        statsObject.removeValue(forKey: "historical")
        encoded[0]["statistics"] = statsObject
        try JSONSerialization.data(withJSONObject: encoded).write(to: library)
        let store = ArticleStore()
        check("test store does not use the persistent article partition", !store.loader.webView.configuration.websiteDataStore.isPersistent)
        check("store loaded the saved record", store.records.count == 1 && store.records[0].status == .saved)
        let recordID = store.records[0].id
        check("loaded excerpt is still the full 51 characters", store.records[0].excerpt == fiftyOne)
        check("loaded cover path is still absent", store.records[0].coverPath == nil)
        check("loaded read is 1.5万+", store.records[0].statistics?.read == "1.5万+")
        check("loaded like is the real zero", store.records[0].statistics?.like == "0")
        check("loaded historical key stays nil", store.records[0].statistics?.historical == nil)
        check("store has not started a page load", store.loader.webView.url == nil && !store.busy)
        func digest() -> SHA256Digest { SHA256.hash(data: try! Data(contentsOf: articleFile)) }
        func current() -> ArticleRecord { store.records.first { $0.id == recordID }! }
        let originalGeneration = store.monitoringGeneration
        store.stopMonitoring()
        let rotated = store.monitoringGeneration
        check("stopMonitoring changes monitoringGeneration", rotated != originalGeneration)
        let libraryBeforeReject = try Data(contentsOf: library)
        let rejected = store.commitMetadata(id: recordID, payload: successPayload, failure: nil, checkedAt: now, session: originalGeneration)
        check("expired monitoringGeneration is rejected", rejected == false)
        check("rejected callback keeps path and saved status", current().path == savedDir.path && current().status == .saved)
        check("rejected callback keeps 1.5万+ and zero", current().statistics?.read == "1.5万+" && current().statistics?.like == "0" && current().statistics?.historical == nil)
        check("rejected callback does not rewrite the library", try Data(contentsOf: library) == libraryBeforeReject)
        check("rejected callback does not rewrite the article", digest() == articleDigest)
        let accepted = store.commitMetadata(id: recordID, payload: successPayload, failure: nil, checkedAt: now, session: rotated)
        check("current monitoringGeneration is accepted", accepted == true)
        check("accepted metadata keeps the saved path and status", current().path == savedDir.path && current().status == .saved)
        check("accepted metadata keeps the article bytes", digest() == articleDigest)
        check("accepted metadata keeps the stored excerpt", current().excerpt == fiftyOne && current().coverURL == saved.coverURL && current().coverPath == nil)
        check("accepted metadata keeps the omitted read", current().statistics?.read == "1.5万+")
        check("accepted metadata stores the refreshed like", current().statistics?.like == "1.5万+")
        check("accepted metadata stores the explicit watching zero", current().statistics?.watching == "0")
        check("accepted metadata marks only the omitted read historical", historicalNames(current().statistics!) == ["read"])
        let libraryAfterAccept = try Data(contentsOf: library)
        store.stopMonitoring()
        let newest = store.monitoringGeneration
        check("a second stopMonitoring rotates the token again", newest != rotated)
        let staleAfterStop = store.commitMetadata(id: recordID, payload: ["statistics": ["like": "9"]], failure: nil, checkedAt: later, session: rotated)
        check("token from before the second stop is rejected", staleAfterStop == false)
        check("stale token does not rewrite the accepted library", try Data(contentsOf: library) == libraryAfterAccept)
        check("stale token keeps the article bytes", digest() == articleDigest)
        let failureAccepted = store.commitMetadata(id: recordID, payload: ["statistics": ["read": "0", "like": "0"]], failure: "网页验证", checkedAt: later, session: newest)
        check("current token accepts a monitoring failure", failureAccepted == true)
        check("failure commit keeps the saved path and status", current().path == savedDir.path && current().status == .saved)
        check("failure commit keeps the article bytes", digest() == articleDigest)
        check("failure commit keeps the previous read", current().statistics?.read == "1.5万+")
        check("failure commit keeps the previous like", current().statistics?.like == "1.5万+")
        check("failure commit does not replace counts from the failed payload", current().statistics?.watching == "0")
        check("failure commit marks retained counts historical", historicalNames(current().statistics!) == ["read", "like", "watching"])
        check("failure commit records the message", current().statistics?.error == "网页验证")
        check("unknown record is rejected", store.commitMetadata(id: UUID(), payload: successPayload, failure: nil, checkedAt: later, session: newest) == false)
        let direct = store.commitMetadata(id: recordID, payload: ["statistics": ["comments": "0"]], failure: nil, checkedAt: later, session: nil)
        check("direct commit without a callback token is accepted", direct == true)
        check("direct commit still preserves path, status, and article bytes", current().path == savedDir.path && current().status == .saved && digest() == articleDigest)
        check("direct commit stores a real comment zero", current().statistics?.comments == "0")
        store.shutdown()
        print("ArticleMetadataChecks: \(checks) passed")
    }
}
