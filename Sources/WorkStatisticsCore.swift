import Foundation

struct WorkStatisticsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct WorkStatistics: Codable, Equatable {
    var likeCount: Int64?
    var commentCount: Int64?
    var collectCount: Int64?
    var viewCount: Int64?
    var viewsNote: String?
    var observedAt: Int64
    var source: String
    var recommendCount: Int64? = nil
    var shareCount: Int64? = nil
    var displayCounts: [String: String]? = nil
    var metricsNote: String? = nil
    var viewCountIsPublic: Bool? = nil
    var coverURL: String? = nil
    var valid: Bool {
        let numbers = [likeCount, commentCount, collectCount, viewCount, recommendCount, shareCount]
        let displays = displayCounts ?? [:]
        return observedAt > 0 && numbers.allSatisfy { $0 == nil || $0! >= 0 }
            && (viewCount == nil || viewCount! > 0 || viewCountIsPublic == true)
            && displays.allSatisfy { ["like", "comment", "collect", "view", "recommend", "share"].contains($0.key)
                && $0.value.range(of: #"^[0-9]{1,19}(?:\.[0-9]{1,3})?[万亿wWkK]?\+?$"#, options: .regularExpression) != nil }
            && (numbers.contains { $0 != nil } || !displays.isEmpty)
            && source.count <= 200 && (metricsNote?.count ?? 0) <= 1000
            && (coverURL?.isEmpty == true ? false : coverURL.map { $0.hasPrefix("https://") && $0.count <= 2048 } ?? true)
    }
    static let deltaKeys = ["like", "comment", "collect", "view", "recommend", "share"]
    private func number(_ key: String) -> Int64? {
        switch key {
        case "like": return likeCount
        case "comment": return commentCount
        case "collect": return collectCount
        case "view": return viewCount
        case "recommend": return recommendCount
        case "share": return shareCount
        default: return nil
        }
    }
    /// 手动刷新的变化对比：仅当新旧两轮都有真实数字且不相等时产生差值。
    func deltas(from previous: WorkStatistics?) -> [WorkStatisticsDelta] {
        guard let previous else { return [] }
        return Self.deltaKeys.compactMap { key in
            guard let old = previous.number(key), let new = number(key), old != new else { return nil }
            return WorkStatisticsDelta(key: key, oldValue: old, newValue: new)
        }
    }
}
struct WorkStatisticsDelta: Codable, Equatable, Identifiable {
    let key: String
    let oldValue: Int64
    let newValue: Int64
    var id: String { key }
    var amount: Int64 { newValue - oldValue }
}
struct WorkStatisticsChange: Codable, Equatable, Identifiable {
    let id: String
    var title: String?
    var deltas: [WorkStatisticsDelta]
    var impact: Int64 {
        deltas.reduce(0) { total, delta in
            let (sum, overflow) = total.addingReportingOverflow(abs(delta.amount))
            return overflow ? Int64.max : sum
        }
    }
}
struct WorkStatisticsEntry: Codable, Equatable {
    var value: WorkStatistics?
    var lastAttemptAt: Int64?
    var issue: String?
}
struct WorkStatisticsLibrary: Codable, Equatable {
    var version = 1
    var entries: [String: WorkStatisticsEntry] = [:]
}
struct WorkStatisticsRepository {
    let fileURL: URL
    func load() throws -> WorkStatisticsLibrary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return WorkStatisticsLibrary() }
        let result = try JSONDecoder().decode(WorkStatisticsLibrary.self, from: Data(contentsOf: fileURL))
        guard result.version == 1, result.entries.count <= 50_000,
              result.entries.allSatisfy({ Self.validID($0.key) && ($0.value.value?.valid ?? true) }) else {
            throw WorkStatisticsError(message: "作品统计库版本或字段无效，原文件保留：" + fileURL.path)
        }
        return result
    }
    func save(_ value: WorkStatisticsLibrary) throws {
        guard value.version == 1, value.entries.count <= 50_000,
              value.entries.allSatisfy({ Self.validID($0.key) && ($0.value.value?.valid ?? true) }) else {
            throw WorkStatisticsError(message: "统计库超过50000项或包含无效数据，原文件保留。")
        }
        _ = try load() // Never overwrite a corrupted existing statistics file.
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
    static func validID(_ id: String) -> Bool {
        id.range(of: #"^(?:[0-9]{19}|bilibili:(?:BV[A-Za-z0-9]{10}|av[0-9]{1,20})|wechat:(?:share|object):[A-Za-z0-9_-]{1,180})$"#, options: .regularExpression) != nil
    }
    static func id(link: String, videoID: String? = nil) -> String? {
        guard let platform = MediaPlatform.detect(link: link) else { return nil }
        let url = MediaPlatform.firstURL(in: link)
        switch platform {
        case .douyin:
            let candidate = videoID ?? url.flatMap { url in
                url.path.range(of: #"/(?:video|note)/[0-9]{19}(?![0-9])"#, options: .regularExpression).flatMap { url.path[$0].split(separator: "/").last.map(String.init) }
            } ?? link.trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.range(of: #"^[0-9]{19}$"#, options: .regularExpression) != nil ? candidate : nil
        case .bilibili:
            let pattern = #"BV[A-Za-z0-9]{10}(?![A-Za-z0-9])"#
            if let text = [videoID, url?.path].compactMap({ $0 }).first(where: { $0.range(of: pattern, options: .regularExpression) != nil }),
               let range = text.range(of: pattern, options: .regularExpression) { return "bilibili:" + text[range] }
            if let path = url?.path, let range = path.range(of: #"av[0-9]{1,20}(?![0-9])"#, options: .regularExpression) { return "bilibili:" + path[range] }
            return nil
        case .wechat:
            if let url, url.path.hasPrefix("/sph/"), let code = url.path.split(separator: "/").last,
               code.range(of: #"^[A-Za-z0-9_-]{1,180}$"#, options: .regularExpression) != nil { return "wechat:share:" + code }
            if let videoID, videoID.range(of: #"^[A-Za-z0-9_-]{1,180}$"#, options: .regularExpression) != nil { return "wechat:object:" + videoID }
            return nil
        case .xiaohongshu: return nil
        }
    }
    static func request(link: String, videoID: String? = nil, homepage: String? = nil) -> WorkStatisticsRequest? {
        guard let id = id(link: link, videoID: videoID), let platform = MediaPlatform.detect(link: link) else { return nil }
        let url = platform == .douyin ? "https://www.douyin.com/video/" + id : MediaPlatform.firstURL(in: link)?.absoluteString
        guard let url else { return nil }
        return WorkStatisticsRequest(id: id, platform: platform.rawValue, link: url, videoID: videoID, homepage: platform == .douyin ? homepage : nil)
    }
}

struct WorkStatisticsRequest: Codable, Equatable {
    let id: String
    let platform: String
    let link: String
    var videoID: String? = nil
    var homepage: String? = nil
    var title: String? = nil
}
