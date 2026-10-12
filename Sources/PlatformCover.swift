import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// 视频封面优先用平台上传的封面图；抓取不带任何 Cookie/凭据，白名单外一律拒绝。
/// 拿不到平台封面时由调用方回退到本地视频首帧，行为与 1.7.4 之前一致。
struct ShiyingPlatformCover<Fallback: View>: View {
    let url: String
    @ViewBuilder var fallback: Fallback
    @State private var image: CGImage?
    private var taskID: String { url }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1.0).resizable().scaledToFill()
            } else {
                fallback
            }
        }
        .clipped()
        .task(id: taskID) {
            image = nil
            let loaded = await PlatformCoverLoader.load(remote: url, cacheRoot: ShiyingPlatformCoverCache.root())
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

enum PlatformCoverPolicy {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let approvedHostSuffixes = ["douyinpic.com", "byteimg.com", "zjcdn.com", "hdslb.com", "qpic.cn"]

    static func approved(_ text: String?) -> URL? {
        guard let text, text.hasPrefix("https://"), text.count <= 2048,
              var parts = URLComponents(string: text), let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil || [80, 443].contains(parts.port!),
              approvedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        parts.fragment = nil
        return parts.url
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        request.setValue("image/avif,image/webp,image/png,image/jpeg,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    /// 重定向仍必须落在白名单内；请求不复制 Cookie 或 Authorization。
    static func redirectRequest(from incoming: URLRequest, redirects: Int) -> URLRequest? {
        guard redirects < 4, let raw = incoming.url, let approved = approved(raw.absoluteString) else { return nil }
        return request(approved)
    }
}

enum PlatformCoverDecoder {
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

    static func image(at url: URL) -> CGImage? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, bytes <= maxBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count == bytes else { return nil }
        return image(data: data)
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

enum ShiyingPlatformCoverCache {
    static var dataRootOverride: URL?
    static let fileLimit = 300
    static let byteLimit = 256 * 1024 * 1024

    static func root() -> URL {
        let base = dataRootOverride ?? shiyingTestDataRoot(fallback: "/tmp/shiying-platform-cover-test")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/拾影")
        return base.appendingPathComponent("video-covers", isDirectory: true)
    }

    static func destination(remote: URL, ext: String, cacheRoot: URL? = nil) -> URL? {
        guard ext.hasPrefix("."), !ext.contains("/"), !ext.contains("..") else { return nil }
        let root = (cacheRoot ?? root()).standardizedFileURL.resolvingSymlinksInPath()
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let dest = root.appendingPathComponent(digest + ext, isDirectory: false).standardizedFileURL.resolvingSymlinksInPath()
        return dest.deletingLastPathComponent().path == root.path ? dest : nil
    }

    static func existing(remote: URL, cacheRoot: URL? = nil) -> URL? {
        for ext in [".jpg", ".png", ".webp", ".gif", ".avif"] {
            guard let dest = destination(remote: remote, ext: ext, cacheRoot: cacheRoot),
                  let values = try? dest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes > 0, bytes <= PlatformCoverDecoder.maxBytes else { continue }
            return dest
        }
        return nil
    }

    static func store(_ data: Data, remote: URL, cacheRoot: URL? = nil) {
        guard let ext = PlatformCoverDecoder.fileExtension(data), let dest = destination(remote: remote, ext: ext, cacheRoot: cacheRoot) else { return }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
            prune(keeping: dest)
        } catch { /* Keep any previous valid cache if the atomic write fails. */ }
    }

    static func prune(keeping: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: keeping.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard file.lastPathComponent.range(of: #"^[a-f0-9]{64}\.(png|jpg|gif|webp|avif)$"#, options: .regularExpression) != nil,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize else { return nil }
            return (file, bytes, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var count = entries.count, total = entries.reduce(0) { $0 + $1.1 }
        for (file, bytes, _) in entries where file != keeping {
            guard count > fileLimit || total > byteLimit else { break }
            if (try? FileManager.default.removeItem(at: file)) != nil { count -= 1; total -= bytes }
        }
    }
}

enum PlatformCoverMemory {
    private final class Box: NSObject { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    static func get(_ key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }
    static func set(_ key: String, _ image: CGImage) {
        cache.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }
}

actor PlatformCoverInFlight {
    static let shared = PlatformCoverInFlight()
    private var tasks: [String: Task<CGImage?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    private let failureRetryInterval: TimeInterval = 600

    func cached(_ key: String) -> CGImage? { PlatformCoverMemory.get(key) }
    func recentlyFailed(_ key: String, now: Date = Date()) -> Bool {
        if let at = failedAt[key], now.timeIntervalSince(at) < failureRetryInterval { return true }
        return false
    }
    func image(for url: String, cacheRoot: URL) async -> CGImage? {
        let key = cacheRoot.standardizedFileURL.path + "|" + url
        if let running = tasks[key] { return await running.value }
        let task = Task<CGImage?, Never> {
            await PlatformCoverLoader.fetch(remote: url, cacheRoot: cacheRoot)
        }
        tasks[key] = task
        let image = await task.value
        tasks.removeValue(forKey: key)
        if image == nil { failedAt[key] = Date() } else { failedAt.removeValue(forKey: key) }
        return image
    }
}

enum PlatformCoverLoader {
    static func load(remote: String, cacheRoot: URL) async -> CGImage? {
        guard let approved = PlatformCoverPolicy.approved(remote) else { return nil }
        let key = cacheRoot.standardizedFileURL.path + "|" + approved.absoluteString
        let inflight = PlatformCoverInFlight.shared
        if let cached = await inflight.cached(key) { return cached }
        if await inflight.recentlyFailed(key) { return nil }
        return await inflight.image(for: approved.absoluteString, cacheRoot: cacheRoot)
    }

    static func fetch(remote: String, cacheRoot: URL) async -> CGImage? {
        guard let approved = PlatformCoverPolicy.approved(remote) else { return nil }
        let key = cacheRoot.standardizedFileURL.path + "|" + approved.absoluteString
        if let file = ShiyingPlatformCoverCache.existing(remote: approved, cacheRoot: cacheRoot),
           let image = await detached({ PlatformCoverDecoder.image(at: file) }) {
            PlatformCoverMemory.set(key, image)
            return image
        }
        guard let data = await PlatformCoverFetcher.shared.data(from: approved),
              let image = await detached({ PlatformCoverDecoder.image(data: data) }) else { return nil }
        await detached { ShiyingPlatformCoverCache.store(data, remote: approved, cacheRoot: cacheRoot) }
        PlatformCoverMemory.set(key, image)
        return image
    }

    private static func detached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}

final class PlatformCoverFetcher: NSObject, URLSessionDataDelegate {
    static let shared = PlatformCoverFetcher()
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
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func data(from url: URL) async -> Data? {
        guard PlatformCoverPolicy.approved(url.absoluteString) != nil else { return nil }
        let box = TaskBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.continuation = continuation
                let task = self.session.dataTask(with: PlatformCoverPolicy.request(url))
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
        guard let clean = PlatformCoverPolicy.redirectRequest(from: request, redirects: redirects) else {
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
        guard status == 200, length <= Int64(PlatformCoverDecoder.maxBytes) else {
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
        if box.data.count > PlatformCoverDecoder.maxBytes {
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
