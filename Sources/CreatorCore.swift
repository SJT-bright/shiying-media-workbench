import Foundation

enum MediaSource: String, CaseIterable, Identifiable {
    case wechat, douyin, bilibili, xiaohongshu, unknown
    var id: String { rawValue }
    var platform: MediaPlatform? { MediaPlatform(rawValue: rawValue) }
    var title: String { platform?.title ?? "来源待确认" }
    var symbol: String { platform?.symbol ?? "questionmark.circle" }
    static func from(link: String) -> MediaSource {
        MediaPlatform.detect(link: link).flatMap { MediaSource(rawValue: $0.rawValue) } ?? .unknown
    }
}

// 博主筛选内核：纯 Foundation。日期、点赞/收藏门槛和排序只在这里计算，UI 不再写这套数学。

struct CreatorInputError: Error, Equatable, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum MediaPlatform: String, Codable, CaseIterable, Identifiable {
    case douyin, bilibili, wechat, xiaohongshu
    var id: String { rawValue }
    var title: String {
        switch self { case .douyin: return "抖音"; case .bilibili: return "B站"; case .wechat: return "视频号"; case .xiaohongshu: return "小红书" }
    }
    var symbol: String {
        switch self { case .douyin: return "music.note"; case .bilibili: return "play.tv.fill"; case .wechat: return "video.fill"; case .xiaohongshu: return "book.closed.fill" }
    }
    var loginURL: URL {
        switch self {
        case .douyin: return URL(string: "https://www.douyin.com/")!
        case .bilibili: return URL(string: "https://www.bilibili.com/")!
        case .wechat: return URL(string: "https://channels.weixin.qq.com/")!
        case .xiaohongshu: return URL(string: "https://www.xiaohongshu.com/explore")!
        }
    }
    var cookieDomains: [String] {
        switch self { case .douyin: return ["douyin.com"]; case .bilibili: return ["bilibili.com"]; case .wechat: return ["weixin.qq.com", "yuanbao.tencent.com"]; case .xiaohongshu: return ["xiaohongshu.com"] }
    }
    var authCookieNames: Set<String> {
        switch self { case .douyin: return ["sessionid", "sessionid_ss", "sid_guard"]; case .bilibili: return ["SESSDATA"]; case .wechat: return ["finder_sessionid", "sessionid", "wxuin", "slave_sid"]; case .xiaohongshu: return ["web_session"] }
    }
    func acceptsCookieDomain(_ domain: String) -> Bool {
        let host = String(domain.drop(while: { $0 == "." })).lowercased()
        return cookieDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    /// Yuanbao sets its own login cookies on the Tencent parent domain. Export
    /// only the known parser credentials, scoped down to the actual API host.
    /// This does not allow navigating to or exporting other Tencent products.
    func sessionCookieDomain(name: String, domain: String) -> String? {
        let host = String(domain.drop(while: { $0 == "." })).lowercased()
        if self == .wechat, host == "tencent.com", ["hy_user", "hy_token", "hy_source"].contains(name) {
            return "yuanbao.tencent.com"
        }
        return acceptsCookieDomain(domain) ? domain : nil
    }
    func allowsNavigation(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        if acceptsCookieDomain(host) { return self != .wechat || host == "yuanbao.tencent.com" || host == "weixin.qq.com" || host.hasSuffix(".weixin.qq.com") }
        switch self {
        case .bilibili: return host == "b23.tv"
        case .wechat: return host == "open.weixin.qq.com" || host == "channels.weixin.qq.com" || host == "mp.weixin.qq.com"
        case .xiaohongshu: return (host == "xhslink.com" || host == "www.xhslink.com")
        default: return false
        }
    }
    static let wechatParserLoginURL = URL(string: "https://yuanbao.tencent.com/")!
    func hasAuthenticationCookies(_ rows: [[String: Any]]) -> Bool {
        if self == .wechat {
            let yuanbao = rows.filter { row in
                guard let domain = row["domain"] as? String else { return false }
                return String(domain.drop(while: { $0 == "." })).lowercased() == "yuanbao.tencent.com"
            }
            let names = Set(yuanbao.compactMap { row -> String? in
                guard let value = row["value"] as? String, !value.isEmpty else { return nil }
                return row["name"] as? String
            })
            if names.isSuperset(of: ["hy_user", "hy_token"]) { return true }
            return rows.contains { row in
                guard let domain = row["domain"] as? String, let name = row["name"] as? String,
                      let value = row["value"] as? String, !value.isEmpty else { return false }
                let host = String(domain.drop(while: { $0 == "." })).lowercased()
                return (host == "weixin.qq.com" || host.hasSuffix(".weixin.qq.com")) && authCookieNames.contains(name)
            }
        }
        return rows.contains { row in
            guard let name = row["name"] as? String, let value = row["value"] as? String else { return false }
            return authCookieNames.contains(name) && !value.isEmpty
        }
    }

    static func detect(link: String) -> MediaPlatform? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^\d{19}$"#, options: .regularExpression) != nil { return .douyin }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let urls = detector?.matches(in: link, range: NSRange(link.startIndex..., in: link)).compactMap(\.url) ?? []
        let candidates = urls.isEmpty ? [URL(string: trimmed)].compactMap { $0 } : urls
        for url in candidates {
            guard let host = url.host?.lowercased(), url.scheme == "https" || url.scheme == "http", url.user == nil, url.password == nil else { continue }
            if host == "yuanbao.tencent.com" || host.hasSuffix(".yuanbao.tencent.com") { continue }
            if let found = allCases.first(where: { $0.acceptsCookieDomain(host) || ($0 == .bilibili && host == "b23.tv") || ($0 == .xiaohongshu && (host == "xhslink.com" || host == "www.xhslink.com")) }) { return found }
        }
        return nil
    }
    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let urls = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
        return urls.first(where: { detect(link: $0.absoluteString) != nil })
            ?? URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var sessionFilename: String { self == .douyin ? "creator-session.json" : "creator-session-\(rawValue).json" }
    var websiteIdentifier: UUID {
        switch self {
        case .douyin: return UUID(uuidString: "8F3C1A2E-6B74-4D15-9C30-1A7E5D2B64F0")!
        case .bilibili: return UUID(uuidString: "9704D4A9-456F-4270-A76B-E073F4389688")!
        case .wechat: return UUID(uuidString: "2D77A848-620F-4A63-87AF-BF3EBF84A198")!
        case .xiaohongshu: return UUID(uuidString: "AFC274C4-6201-4026-AB62-2568958A83FD")!
        }
    }
}

struct CreatorPost: Codable, Identifiable, Equatable {
    var id: String
    var link: String
    var title: String
    var author: String
    var createdAt: Int64?
    var diggCount: Int64?
    var collectCount: Int64?
    var cover: String?
    var isVideo: Bool
    var platformRaw: String? = nil
    var mediaURL: String? = nil
    var isCoauthored: Bool? = nil
    var statistics: WorkStatistics? = nil
}

enum CreatorSort: String, Codable, CaseIterable {
    case latest
    case likes
    case collects
}

struct CreatorFilter: Codable, Equatable {
    var fromDay: String? = nil
    var toDay: String? = nil
    var likesAbove: Int64? = nil
    var collectsAbove: Int64? = nil
    var keyword: String = ""
    var sort: CreatorSort = .latest
}

enum CreatorCore {
    /// 上海日历日。抖音没有夏令时，00:00 的 epoch 是整秒。
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    /// 万门槛。空字符串是没填，返回 nil；非法、负数、超过 4 位小数、溢出都抛错，不返回 nil。
    static func parseWanThreshold(_ text: String) throws -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        var body = trimmed
        if body.hasSuffix("万") {
            body = String(body.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if body.isEmpty {
            throw CreatorInputError(message: "万门槛无效：请填写非负数字，最多 4 位小数。")
        }
        if body.contains("-") {
            throw CreatorInputError(message: "万门槛无效：不能为负数。")
        }
        if body.range(of: #"^[0-9]+\.[0-9]{5,}$"#, options: .regularExpression) != nil {
            throw CreatorInputError(message: "万门槛无效：最多 4 位小数。")
        }
        guard body.range(of: #"^[0-9]+(?:\.[0-9]{1,4})?$"#, options: .regularExpression) != nil else {
            throw CreatorInputError(message: "万门槛无效：请填写非负数字，最多 4 位小数。")
        }
        guard let decimal = Decimal(string: body, locale: Locale(identifier: "en_US_POSIX")) else {
            throw CreatorInputError(message: "万门槛无效：请填写非负数字，最多 4 位小数。")
        }
        if decimal < 0 {
            throw CreatorInputError(message: "万门槛无效：不能为负数。")
        }
        let scaled = decimal * Decimal(10_000)
        // 最多 4 位小数乘 10000 后必须是整数。这里只拒绝小数残留，不做四舍五入。
        var integral = Decimal()
        var source = scaled
        NSDecimalRound(&integral, &source, 0, .down)
        if integral != scaled {
            throw CreatorInputError(message: "万门槛无效：不能精确换成整数个。")
        }
        if scaled > Decimal(Int64.max) || scaled < 0 {
            throw CreatorInputError(message: "万门槛无效：超出整数范围。")
        }
        let result = NSDecimalNumber(decimal: scaled).int64Value
        if Decimal(result) != scaled {
            throw CreatorInputError(message: "万门槛无效：超出整数范围。")
        }
        return result
    }

    /// nil 表示筛选器可用。非法日期不会被当成“不限”。
    static func validate(_ filter: CreatorFilter) -> String? {
        if let reason = dateError(filter.fromDay, label: "开始日期") { return reason }
        if let reason = dateError(filter.toDay, label: "结束日期") { return reason }
        if let from = dayStart(filter.fromDay), let to = dayStart(filter.toDay), to < from {
            return "结束日期早于开始日期。"
        }
        return nil
    }

    /// 唯一的过滤和排序入口。筛选器非法时返回空，不会把坏日期当成不限。
    static func apply(_ posts: [CreatorPost], filter: CreatorFilter) -> [CreatorPost] {
        guard validate(filter) == nil else { return [] }
        let from = dayStart(filter.fromDay)
        let toExclusive = dayStart(filter.toDay).map { $0 + 86_400 }
        let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = posts.filter { post in
            if !keyword.isEmpty,
               post.title.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
            if from != nil || toExclusive != nil {
                guard let created = post.createdAt else { return false }
                if let from, created < from { return false }
                if let toExclusive, created >= toExclusive { return false }
            }
            if let likes = filter.likesAbove {
                guard let digg = post.diggCount, digg > likes else { return false }
            }
            if let collects = filter.collectsAbove {
                guard let collect = post.collectCount, collect > collects else { return false }
            }
            return true
        }
        return matched.sorted { compare($0, $1, filter.sort) }
    }

    /// 当前关键字命中、但因启用中的日期/点赞/收藏门槛缺字段而被排除的作品数。
    static func unknownFieldCount(_ posts: [CreatorPost], filter: CreatorFilter) -> Int {
        guard validate(filter) == nil else { return 0 }
        let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateOn = !blank(filter.fromDay) || !blank(filter.toDay)
        var count = 0
        for post in posts {
            if !keyword.isEmpty,
               post.title.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                continue
            }
            let unknown = (filter.likesAbove != nil && post.diggCount == nil)
                || (filter.collectsAbove != nil && post.collectCount == nil)
                || (dateOn && post.createdAt == nil)
            if unknown { count += 1 }
        }
        return count
    }

    private static func blank(_ text: String?) -> Bool {
        guard let text else { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func dateError(_ text: String?, label: String) -> String? {
        if blank(text) { return nil }
        if dayStart(text) == nil {
            return "\(label)无效，请按上海时区填写 yyyy-MM-dd。"
        }
        return nil
    }

    /// 当日 00:00（含）的 epoch 秒。空白返回 nil；非法日期返回 nil，由 validate 报错，不能当不限。
    private static func dayStart(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let day = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if day.isEmpty { return nil }
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let dayNumber = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        calendar.locale = Locale(identifier: "en_US_POSIX")
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = shanghai
        components.year = year
        components.month = month
        components.day = dayNumber
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == dayNumber else { return nil }
        // 上海偏移是整小时，00:00 本身就是整秒。rounded 只吸收 Double 的二进制噪声。
        let seconds = date.timeIntervalSince1970
        let nearest = seconds.rounded()
        guard abs(seconds - nearest) < 0.001, nearest >= 0, nearest < Double(Int64.max) else { return nil }
        return Int64(nearest)
    }

    private static func compare(_ lhs: CreatorPost, _ rhs: CreatorPost, _ sort: CreatorSort) -> Bool {
        let left: Int64?
        let right: Int64?
        switch sort {
        case .latest:
            left = lhs.createdAt
            right = rhs.createdAt
        case .likes:
            left = lhs.diggCount
            right = rhs.diggCount
        case .collects:
            left = lhs.collectCount
            right = rhs.collectCount
        }
        switch (left, right) {
        case let (l?, r?) where l != r:
            return l > r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
    }
}
