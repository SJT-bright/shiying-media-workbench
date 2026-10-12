import Foundation
import AppKit
@main struct ArticleChecks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiying-article-checks-" + UUID().uuidString)
        ArticleStore.dataRootOverride = root
        let suite = ArticleStore.testPreferencesSuite(root: root)
        let preferences = UserDefaults(suiteName: suite)!
        defer { ArticleStore.dataRootOverride = nil; preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ label: String,_ value: Bool) { precondition(value,"FAIL " + label); checks += 1; print("PASS " + label) }
        let a = "https://mp.weixin.qq.com/s/TestArticle", b = "https://mp.weixin.qq.com/s/SecondArticle"
        check("share text becomes deduplicated article links", try ArticleInput.links("文章 " + a + "\n" + b + "\n" + a) == [a,b])
        check("pasted Markdown link keeps the complete article ID", try ArticleInput.links("[" + a + "](" + a + ")") == [a])
        let secret = "https://mp.weixin.qq.com/s?__biz=QQ%3D%3D&mid=123&idx=1&sn=" + String(repeating: "a",count: 32) + "&key=SYNTHETIC_PRIVATE&pass_ticket=SYNTHETIC_PRIVATE"
        let canonical = try ArticleInput.canonical(secret)
        check("authentication query is never persisted", !canonical.contains("PRIVATE") && !canonical.contains("pass_ticket") && canonical.contains("QQ%3D%3D"))
        check("foreign URL cannot enter article queue", (try? ArticleInput.links(a + "\nhttps://www.douyin.com/video/7000000000000000001")) == nil)
        check("oversized list rejected rather than truncated", (try? ArticleInput.links(Array(repeating:a,count:201).joined(separator:"\n"))) == nil)
        check("homepage is not treated as article", (try? ArticleInput.canonical("https://mp.weixin.qq.com/mp/profile_ext?action=home")) == nil)
        let store = ArticleStore()
        check("new module does not automatically load or download", store.records.isEmpty && !store.busy && !FileManager.default.fileExists(atPath: root.path))
        check("test loader never opens the persistent article partition", !store.loader.webView.configuration.websiteDataStore.isPersistent)
        let chosen = root.appendingPathComponent("chosen-article-folder").path
        store.folder = chosen
        check("same test root restores its own article folder", ArticleStore().folder == chosen)
        let otherRoot = root.appendingPathComponent("other-root"), otherSuite = ArticleStore.testPreferencesSuite(root: root.appendingPathComponent("other-root"))
        ArticleStore.dataRootOverride = otherRoot
        let other = ArticleStore()
        check("different test roots cannot inherit another article folder", otherSuite != suite && other.folder == otherRoot.appendingPathComponent("article-files").path)
        other.folder = otherRoot.appendingPathComponent("other-folder").path
        check("other test root cannot overwrite this root's preferences", preferences.string(forKey: "articleFolder") == chosen)
        UserDefaults(suiteName: otherSuite)!.removePersistentDomain(forName: otherSuite)
        ArticleStore.dataRootOverride = root
        store.text = a + "\n" + b; store.addLinks()
        check("adding links persists only independent article records", store.records.count == 2 && !store.busy && FileManager.default.fileExists(atPath: root.appendingPathComponent("articles/article-library.json").path) && !FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path))
        store.addLinks();check("repeated paste does not duplicate records",store.records.count==2)
        check("restart retains queue without starting it",ArticleStore().records.count==2 && !ArticleStore().busy)
        let file=root.appendingPathComponent("articles/article-library.json"), bad=Data("{invalid".utf8)
        try bad.write(to:file);store.text = "https://mp.weixin.qq.com/s/ThirdArticle";store.addLinks()
        check("failed persistence keeps old displayed records",store.records.count==2 && store.error?.contains("保存失败")==true)
        check("corrupted article library is never overwritten",try Data(contentsOf:file)==bad)
        check("restart exposes bad article library",ArticleStore().error != nil)
        print("ArticleChecks: \(checks) passed")
    }
}
