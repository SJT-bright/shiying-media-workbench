import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// 文章封面只读本地文件。旧记录和未保存文章才从已批准的微信图片地址拉取，
/// 结果放进独立 cacheRoot 或内存，不改用户原来的文章文件。
struct ArticleCoverView: View {
    let record: ArticleRecord
    let cacheRoot: URL
    @State private var image: NSImage?
    private var taskID: String { "\(record.id.uuidString)|\(record.coverPath ?? "")|\(record.coverURL ?? "")|\(record.path ?? "")" }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.06))
            Image(systemName: "doc.text")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("文章封面")
        .task(id: taskID) { await load() }
    }

    private func load() async {
        image = nil
        let local = ArticleCardContent.localCover(record)
        let remote = ArticleCardContent.approvedCover(record.coverURL)
        let articlePath = record.path
        let root = cacheRoot
        let rendered = await ArticleCoverLoader.load(local: local, remote: remote, cacheRoot: root, articlePath: articlePath)
        guard !Task.isCancelled, let rendered else { return }
        image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
    }
}

enum ArticleCoverDecoder {
    static let maxBytes = 32 * 1024 * 1024
    static let maxPixels = 80_000_000
    static let thumbnailPixels = 640

    static func fileExtension(_ data: Data) -> String? {
        if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) { return ".png" }
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return ".jpg" }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { return ".gif" }
        if data.count >= 12, data.starts(with: Data("RIFF".utf8)), data.subdata(in: 8..<12) == Data("WEBP".utf8) { return ".webp" }
        if data.count > 16, data.subdata(in: 4..<8) == Data("ftyp".utf8) {
            let brand = data.subdata(in: 8..<12)
            if brand == Data("avif".utf8) || brand == Data("avis".utf8) { return ".avif" }
        }
        return nil
    }

    static func image(data: Data) -> CGImage? {
        return decode(data)
    }

    static func image(at url: URL) -> CGImage? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, bytes <= maxBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count == bytes else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= maxBytes, let ext = fileExtension(data), let uti = typeIdentifier(ext) else { return nil }
        let hint = [kCGImageSourceTypeIdentifierHint: uti] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, hint), CGImageSourceGetCount(source) > 0 else { return nil }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            if width <= 0 || height <= 0 || width > 20_000 || height > 20_000 || width * height > maxPixels { return nil }
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              image.width > 0, image.height > 0, image.width * image.height <= maxPixels else { return nil }
        return image
    }

    private static func typeIdentifier(_ ext: String) -> String? {
        switch ext {
        case ".png": return "public.png"
        case ".jpg": return "public.jpeg"
        case ".gif": return "com.compuserve.gif"
        case ".webp": return "org.webmproject.webp"
        case ".avif": return "public.avif"
        default: return nil
        }
    }
}

enum ArticleCoverPolicy {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://mp.weixin.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/gif,*/*;q=0.1", forHTTPHeaderField: "Accept")
        return request
    }

    /// 只跟随微信图片白名单。返回的请求不复制 Cookie 或 Authorization。
    static func redirectRequest(from incoming: URLRequest, redirects: Int) -> URLRequest? {
        guard redirects < 4, let raw = incoming.url, let approved = ArticleCardContent.approvedCover(raw.absoluteString) else { return nil }
        return request(approved)
    }
}

enum ArticleCoverCache {
    static func destination(remote: URL, cacheRoot: URL, ext: String, articlePath: String?) -> URL? {
        guard ext.hasPrefix("."), !ext.contains("/"), !ext.contains("..") else { return nil }
        let root = cacheRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard root.isFileURL else { return nil }
        if let articlePath, overlapsArticle(root, articlePath) { return nil }
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let dest = root.appendingPathComponent(digest + ext, isDirectory: false).standardizedFileURL.resolvingSymlinksInPath()
        guard dest.deletingLastPathComponent().path == root.path else { return nil }
        if let articlePath, overlapsArticle(dest, articlePath) { return nil }
        return dest
    }

    static func existing(remote: URL, cacheRoot: URL, articlePath: String?) -> URL? {
        guard let ext = [".png", ".jpg", ".gif", ".webp", ".avif"].first(where: {
            guard let dest = destination(remote: remote, cacheRoot: cacheRoot, ext: $0, articlePath: articlePath) else { return false }
            return isReadableImage(dest)
        }), let dest = destination(remote: remote, cacheRoot: cacheRoot, ext: ext, articlePath: articlePath) else { return nil }
        return dest
    }

    static func store(_ data: Data, remote: URL, cacheRoot: URL, articlePath: String?) {
        guard let ext = ArticleCoverDecoder.fileExtension(data),
              let dest = destination(remote: remote, cacheRoot: cacheRoot, ext: ext, articlePath: articlePath) else { return }
        let root = dest.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard destination(remote: remote, cacheRoot: root, ext: ext, articlePath: articlePath) == dest else { return }
            try data.write(to: dest, options: .atomic)
            prune(root: root, keeping: dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
        }
    }

    private static func isReadableImage(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, bytes <= ArticleCoverDecoder.maxBytes else { return false }
        return true
    }

    private static func prune(root: URL, keeping: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard file.lastPathComponent.range(of: #"^[a-f0-9]{64}\.(png|jpg|gif|webp|avif)$"#, options: .regularExpression) != nil,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize else { return nil }
            return (file, bytes, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var count = entries.count, total = entries.reduce(0) { $0 + $1.1 }
        for (file, bytes, _) in entries where file != keeping {
            guard count > 200 || total > 128 * 1024 * 1024 else { break }
            if (try? FileManager.default.removeItem(at: file)) != nil { count -= 1; total -= bytes }
        }
    }

    private static func overlapsArticle(_ url: URL, _ articlePath: String) -> Bool {
        let article = URL(fileURLWithPath: articlePath).standardizedFileURL.resolvingSymlinksInPath()
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = article.path
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

enum ArticleCoverMemory {
    private final class Box: NSObject { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 200
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    static func get(_ key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }
    static func set(_ key: String, _ image: CGImage) {
        cache.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }
    static func key(local url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return "local|\(url.standardizedFileURL.resolvingSymlinksInPath().path)|\(size)|\(date.timeIntervalSinceReferenceDate)"
    }
    static func key(remote url: URL) -> String { "remote|" + url.absoluteString }
}

enum ArticleCoverLoader {
    static func load(local: URL?, remote: URL?, cacheRoot: URL, articlePath: String?) async -> CGImage? {
        if let local {
            if let key = ArticleCoverMemory.key(local: local), let cached = ArticleCoverMemory.get(key) { return cached }
            if let image = await detached({ ArticleCoverDecoder.image(at: local) }) {
                if let key = ArticleCoverMemory.key(local: local) { ArticleCoverMemory.set(key, image) }
                return image
            }
        }
        guard let remote else { return nil }
        let remoteKey = ArticleCoverMemory.key(remote: remote)
        if let cached = ArticleCoverMemory.get(remoteKey) { return cached }
        if let file = ArticleCoverCache.existing(remote: remote, cacheRoot: cacheRoot, articlePath: articlePath),
           let image = await detached({ ArticleCoverDecoder.image(at: file) }) {
            ArticleCoverMemory.set(remoteKey, image)
            return image
        }
        guard let data = await ArticleCoverFetcher.shared.data(from: remote),
              let image = await detached({ ArticleCoverDecoder.image(data: data) }) else { return nil }
        await detached { ArticleCoverCache.store(data, remote: remote, cacheRoot: cacheRoot, articlePath: articlePath) }
        ArticleCoverMemory.set(remoteKey, image)
        return image
    }

    private static func detached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}

final class ArticleCoverFetcher: NSObject, URLSessionDataDelegate {
    static let shared = ArticleCoverFetcher()
    private let lock = NSLock()
    private var boxes: [Int: TaskBox] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func data(from url: URL) async -> Data? {
        guard let approved = ArticleCardContent.approvedCover(url.absoluteString) else { return nil }
        let box = TaskBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.continuation = continuation
                let task = self.session.dataTask(with: ArticleCoverPolicy.request(approved))
                self.lock.lock()
                box.task = task
                self.boxes[task.taskIdentifier] = box
                let cancelled = box.cancelled
                self.lock.unlock()
                if cancelled {
                    task.cancel()
                    self.finish(task, nil)
                    return
                }
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            box.cancelled = true
            let task = box.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let box = boxes[task.taskIdentifier]
        let redirects = box?.redirects ?? 0
        lock.unlock()
        guard let clean = ArticleCoverPolicy.redirectRequest(from: request, redirects: redirects) else {
            lock.lock(); box?.failed = true; lock.unlock()
            task.cancel()
            completionHandler(nil)
            return
        }
        lock.lock(); box?.redirects = redirects + 1; lock.unlock()
        completionHandler(clean)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let length = response.expectedContentLength
        guard status == 200, length <= Int64(ArticleCoverDecoder.maxBytes) else {
            lock.lock(); boxes[dataTask.taskIdentifier]?.failed = true; lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.lock(); boxes[dataTask.taskIdentifier]?.accepted = true; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let box = boxes[dataTask.taskIdentifier]
        lock.unlock()
        guard let box, !box.failed else { return }
        box.data.append(data)
        if box.data.count > ArticleCoverDecoder.maxBytes {
            box.failed = true
            box.data.removeAll(keepingCapacity: false)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let box = boxes[task.taskIdentifier]
        let data = (error == nil && box?.accepted == true && box?.failed != true) ? box?.data : nil
        lock.unlock()
        finish(task, data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        challengeDisposition(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        challengeDisposition(challenge, completionHandler)
    }

    private func challengeDisposition(_ challenge: URLAuthenticationChallenge, _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func finish(_ task: URLSessionTask, _ data: Data?) {
        lock.lock()
        let box = boxes.removeValue(forKey: task.taskIdentifier)
        let continuation = box?.continuation
        box?.continuation = nil
        lock.unlock()
        continuation?.resume(returning: data)
    }

    private final class TaskBox {
        var task: URLSessionTask?
        var continuation: CheckedContinuation<Data?, Never>?
        var data = Data()
        var redirects = 0
        var accepted = false
        var failed = false
        var cancelled = false
    }
}
