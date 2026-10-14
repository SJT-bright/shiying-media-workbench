import Foundation
import Darwin

struct CreatorSubscription: Codable, Equatable, Identifiable {
    var id = UUID()
    let platform: MediaPlatform
    let creatorID: String
    let homepage: String
    var name: String
    var collectionID: UUID
    var quality: String
    var includeAudio: Bool
    var createdAt = Date()
    var lastCheckedAt: Date?
    var lastAddedCount: Int = 0
    var lastExistingCount: Int = 0
    var lastScanComplete: Bool = false
    var lastMessage: String = "尚未更新"
    var lastQueuedItemIDs: [UUID]? = nil
    var identity: String { platform.rawValue + ":" + creatorID }
}

struct CreatorSubscriptionLibrary: Codable, Equatable {
    var version = 1
    var subscriptions: [CreatorSubscription] = []
}

enum CreatorSubscriptionCore {
    static func homepage(platform: MediaPlatform, creatorID: String, url: String) throws -> String {
        guard !creatorID.isEmpty, creatorID.utf8.count <= 256,
              let parts = URLComponents(string: url), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil else {
            throw CreatorInputError(message: "请先采集有效的博主主页，再订阅。")
        }
        let expected: String
        switch platform {
        case .douyin:
            guard creatorID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
                  parts.host == "www.douyin.com", parts.path == "/user/" + creatorID else {
                throw CreatorInputError(message: "采集结果没有对应的抖音博主主页。")
            }
            expected = "https://www.douyin.com/user/" + creatorID
        case .bilibili:
            guard creatorID.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                  parts.host == "space.bilibili.com", parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == creatorID else {
                throw CreatorInputError(message: "采集结果没有对应的B站博主主页。")
            }
            expected = "https://space.bilibili.com/" + creatorID
        case .xiaohongshu:
            guard creatorID.range(of: #"^[a-fA-F0-9]{24}$"#, options: .regularExpression) != nil,
                  ["www.xiaohongshu.com", "xiaohongshu.com"].contains(parts.host ?? ""),
                  parts.path == "/user/profile/" + creatorID else {
                throw CreatorInputError(message: "采集结果没有对应的小红书博主主页。")
            }
            expected = "https://www.xiaohongshu.com/user/profile/" + creatorID
        case .wechat:
            throw CreatorInputError(message: "视频号当前仅支持单条分享解析，尚未提供可更新的博主主页。")
        }
        return expected
    }

    static func validate(_ library: CreatorSubscriptionLibrary) throws {
        guard library.version == 1, library.subscriptions.count <= 5000,
              Set(library.subscriptions.map(\.id)).count == library.subscriptions.count,
              Set(library.subscriptions.map(\.identity)).count == library.subscriptions.count else {
            throw CreatorInputError(message: "订阅库格式、版本或唯一性无效，原文件保留。")
        }
        for item in library.subscriptions {
            guard try homepage(platform: item.platform, creatorID: item.creatorID, url: item.homepage) == item.homepage,
                  !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.name.utf8.count <= 1024, ["480", "720", "highest"].contains(item.quality),
                  item.lastAddedCount >= 0, item.lastExistingCount >= 0,
                  item.lastMessage.utf8.count <= 8192 else {
                throw CreatorInputError(message: "订阅内容无效，原文件保留。")
            }
        }
    }

    static func missing(_ posts: [CreatorPost], platform: MediaPlatform, known: Set<String>) -> [CreatorPost] {
        var seen = known
        return posts.filter { post in
            guard post.isVideo, MediaPlatform.detect(link: post.link) == platform,
                  post.platformRaw == nil || post.platformRaw == platform.rawValue,
                  BatchLinkParser.videoID(from: post.link) == post.id,
                  let key = BatchLinkParser.identity(for: post.link, videoID: post.id),
                  !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

/// Separate, versioned local database. Lock + expected-byte comparison protects concurrent writers.
final class CreatorSubscriptionRepository {
    let fileURL: URL
    private var expected: Data?
    private var loaded = false
    init(fileURL: URL) { self.fileURL = fileURL }
    private let limit = 16 * 1024 * 1024

    private func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? limit + 1) <= limit else {
            throw CreatorInputError(message: "订阅库不是有效的本地文件或超过容量，原文件保留。")
        }
        return try Data(contentsOf: fileURL)
    }

    func load() throws -> CreatorSubscriptionLibrary {
        let bytes = try read()
        let library = try bytes.map { try JSONDecoder().decode(CreatorSubscriptionLibrary.self, from: $0) } ?? CreatorSubscriptionLibrary()
        try CreatorSubscriptionCore.validate(library)
        expected = bytes; loaded = true
        return library
    }

    func save(_ library: CreatorSubscriptionLibrary) throws {
        guard loaded else { throw CreatorInputError(message: "订阅库尚未成功读取，未写入。") }
        try CreatorSubscriptionCore.validate(library)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(library)
        guard bytes.count <= limit else { throw CreatorInputError(message: "订阅库超过容量，未写入。") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = fileURL.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CreatorInputError(message: "订阅库正在被另一个窗口写入，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }
        guard try read() == expected else {
            throw CreatorInputError(message: "订阅库已被其它窗口修改，请重新打开后再操作；现有文件保留。")
        }
        if let expected { try expected.write(to: fileURL.deletingPathExtension().appendingPathExtension("backup.json"), options: .atomic) }
        try bytes.write(to: fileURL, options: .atomic)
        expected = bytes
    }
}
