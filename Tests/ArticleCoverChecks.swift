import Foundation
import AppKit

@main struct ArticleCoverChecks {
    static func main() throws {
        var checks = 0
        func check(_ label: String, _ value: Bool) {
            precondition(value, "FAIL " + label)
            checks += 1
            print("PASS " + label)
        }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAACXBIWXMAAAABAAAAAQBPJcTWAAAAEklEQVR4nGP8w4AdsOAQH6QSANBkARqrv8JBAAAAAElFTkSuQmCC")!
        check("png magic is recognized", ArticleCoverDecoder.fileExtension(png) == ".png")
        check("gif webp avif and jpeg magics are recognized",
              ArticleCoverDecoder.fileExtension(Data("GIF89a".utf8)) == ".gif"
              && ArticleCoverDecoder.fileExtension(Data("RIFF".utf8) + Data(count: 4) + Data("WEBP".utf8)) == ".webp"
              && ArticleCoverDecoder.fileExtension(Data(count: 4) + Data("ftypavis".utf8) + Data(count: 8)) == ".avif"
              && ArticleCoverDecoder.fileExtension(Data([0xFF, 0xD8, 0xFF, 0xD9])) == ".jpg")
        check("non images and oversized bytes are rejected", ArticleCoverDecoder.fileExtension(Data("not-an-image".utf8)) == nil && ArticleCoverDecoder.image(data: Data(count: ArticleCoverDecoder.maxBytes + 1)) == nil)
        var decodedOffMain = false
        var decoded: CGImage?
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            decodedOffMain = !Thread.isMainThread
            decoded = ArticleCoverDecoder.image(data: png)
            completed.signal()
        }
        completed.wait()
        check("thumbnail decodes off the main thread", decodedOffMain && decoded?.width == 8 && decoded?.height == 8)
        check("broken png does not decode", ArticleCoverDecoder.image(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])) == nil)

        check("foreign cover redirects are refused", ArticleCoverPolicy.redirectRequest(from: URLRequest(url: URL(string: "https://evil.example/a.png")!), redirects: 0) == nil)
        check("too many redirects are refused", ArticleCoverPolicy.redirectRequest(from: URLRequest(url: URL(string: "https://mmbiz.qpic.cn/mmbiz_png/a")!), redirects: 4) == nil)
        var credentialed = URLRequest(url: URL(string: "http://user:secret@mmbiz.qpic.cn/mmbiz_png/a")!)
        credentialed.setValue("SECRET", forHTTPHeaderField: "Cookie")
        credentialed.setValue("Bearer SECRET", forHTTPHeaderField: "Authorization")
        check("credentialed image url is not approved", ArticleCardContent.approvedCover(credentialed.url?.absoluteString) == nil)
        var redirected = URLRequest(url: URL(string: "http://mmbiz.qpic.cn/mmbiz_png/a")!)
        redirected.setValue("SECRET", forHTTPHeaderField: "Cookie")
        redirected.setValue("Bearer SECRET", forHTTPHeaderField: "Authorization")
        let clean = ArticleCoverPolicy.redirectRequest(from: redirected, redirects: 0)
        check("approved redirect drops cookies and authorization",
              clean?.url?.scheme == "https" && clean?.url?.host == "mmbiz.qpic.cn"
              && clean?.value(forHTTPHeaderField: "Cookie") == nil
              && clean?.value(forHTTPHeaderField: "Authorization") == nil
              && clean?.value(forHTTPHeaderField: "Referer") == "https://mp.weixin.qq.com/")
        check("lookalike wechat host is refused", ArticleCardContent.approvedCover("https://mmbiz.qpic.cn.evil/a.png") == nil)
        check("nonstandard image port is refused", ArticleCardContent.approvedCover("https://mmbiz.qpic.cn:444/a.png") == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("article-cover-checks-" + UUID().uuidString)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let article = root.appendingPathComponent("article", isDirectory: true)
        try FileManager.default.createDirectory(at: article, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = URL(string: "https://mmbiz.qpic.cn/mmbiz_png/test/0")!
        let dest = ArticleCoverCache.destination(remote: remote, cacheRoot: cache, ext: ".png", articlePath: article.path)
        check("cache file stays inside cache root", dest?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == cache.standardizedFileURL.resolvingSymlinksInPath().path)
        check("article directory is not a cache destination", ArticleCoverCache.destination(remote: remote, cacheRoot: article, ext: ".png", articlePath: article.path) == nil)
        ArticleCoverCache.store(png, remote: remote, cacheRoot: article, articlePath: article.path)
        check("refused cache does not write the article directory", try FileManager.default.contentsOfDirectory(at: article, includingPropertiesForKeys: nil).isEmpty)
        ArticleCoverCache.store(png, remote: remote, cacheRoot: cache, articlePath: article.path)
        let stored = try Data(contentsOf: dest!)
        check("cache stores the original image bytes", stored == png)
        let before = stored
        let fromDisk = ArticleCoverDecoder.image(at: dest!)
        let after = try Data(contentsOf: dest!)
        check("reading a local cover does not change its bytes", before == after && fromDisk?.width == 8)
        check("main-thread file decode still returns a thumbnail", fromDisk != nil)
        let session = URLSessionConfiguration.ephemeral
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        check("ephemeral configuration can drop cookies and credentials", session.httpCookieStorage == nil && session.urlCredentialStorage == nil)
        print("ArticleCoverChecks: \(checks) passed")
    }
}
