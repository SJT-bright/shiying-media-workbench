import Foundation

enum ArticleStatus: String, Codable { case pending = "待保存", reading = "读取中", saving = "保存中", saved = "已保存", failed = "失败" }
struct ArticleRecord: Codable, Identifiable {
    var id = UUID()
    var link: String
    var title = "等待读取文章"
    var account = "公众号"
    var author = ""
    var published = ""
    var imageCount = 0
    var characters = 0
    var bytes: Int64 = 0
    var path: String? = nil
    var status: ArticleStatus = .pending
    var error: String? = nil
    var date = Date()
    var excerpt: String? = nil
    var coverURL: String? = nil
    var coverPath: String? = nil
    var statistics: ArticleStatistics? = nil
    var available: Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("文章.html").path)
    }
}
struct ArticlePreview: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    var recordID: UUID? = nil
}
enum ArticleInput {
    static func canonical(_ text: String) throws -> String {
        guard let parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme), parts.host == "mp.weixin.qq.com",
              parts.user == nil, parts.password == nil, parts.port == nil || [80,443].contains(parts.port!) else {
            throw WorkStatisticsError(message: "请粘贴公众号文章链接，来源必须是 mp.weixin.qq.com。")
        }
        let path = parts.path
        if path.range(of: #"^/s/[A-Za-z0-9_-]{1,180}/?$"#, options: .regularExpression) != nil {
            return "https://mp.weixin.qq.com" + (path.hasSuffix("/") ? String(path.dropLast()) : path)
        }
        let fields = ["__biz", "mid", "idx", "sn"]
        var values: [String: String] = [:]
        for field in fields { values[field] = parts.queryItems?.first { $0.name == field }?.value }
        guard ["/s", "/s/"].contains(path), fields.allSatisfy({ !(values[$0] ?? "").isEmpty && values[$0]!.count <= 256 }),
              values["mid"]!.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              values["idx"]!.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              values["sn"]!.range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil else {
            throw WorkStatisticsError(message: "请粘贴一篇文章的完整分享链接；公众号主页不能当作文章保存。")
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return "https://mp.weixin.qq.com/s?" + fields.map { $0 + "=" + values[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
    }
    static func links(_ text: String) throws -> [String] {
        guard text.utf8.count <= 1_048_576 else { throw WorkStatisticsError(message: "输入超过1 MiB，请分批添加。") }
        let regex = try NSRegularExpression(pattern: #"https?://[^\s<>\"　\]\)]+"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty, matches.count <= 200 else { throw WorkStatisticsError(message: "一次支持1至200篇文章链接；不会截断。") }
        var result: [String] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "，。！!；;）)]}>'\".,"))
            let link = try canonical(raw)
            if !result.contains(link) { result.append(link) }
        }
        return result
    }
}

struct ArticleStatistics: Codable {
    var read: String?
    var like: String?
    var watching: String?
    var comments: String?
    var checkedAt: Date?
    var error: String?
    var historical: [String]? = nil
    static func publicValue(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 32 else { return nil }
        return trimmed.range(of: #"^(?:[0-9]{1,12}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?)(?:万|亿)?\+?$"#, options: .regularExpression) != nil ? trimmed : nil
    }
    static func snapshot(_ value: [String: Any]) -> ArticleStatistics {
        let metrics = value["statistics"] as? [String: Any] ?? [:]
        return ArticleStatistics(read: publicValue(metrics["read"]), like: publicValue(metrics["like"]), watching: publicValue(metrics["watching"]), comments: publicValue(metrics["comments"]), checkedAt: Date())
    }
}

enum ArticleCardContent {
    static func plainText(_ html: String) -> String {
        var result = html
        for pattern in [#"(?is)<head\b.*?</head>"#, #"(?is)<(?:script|style)\b.*?</(?:script|style)>"#, #"(?s)<[^>]+>"#] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let entities = [("&nbsp;", " "), ("&#160;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")]
        for (key, value) in entities { result = result.replacingOccurrences(of: key, with: value) }
        return result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func snippet(_ text: String) -> String {
        let cleaned = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(cleaned.prefix(50)) + (cleaned.count > 50 ? "..." : "")
    }
    static func storedExcerpt(_ record: ArticleRecord) -> String {
        if let excerpt = record.excerpt, !excerpt.isEmpty { return snippet(excerpt) }
        guard let path = record.path else { return "等待读取文章正文" }
        let file = URL(fileURLWithPath: path).appendingPathComponent("文章.html")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_388_608,
              let raw = try? String(contentsOf: file, encoding: .utf8), raw.utf8.count <= 8_388_608 else { return "等待读取文章正文" }
        // Existing exports place public metadata before the body and source after <hr>.
        var body = raw.components(separatedBy: "<body>").last ?? raw
        if let end = body.range(of: "</p>") { body = String(body[end.upperBound...]) }
        if let end = body.range(of: "<hr>") { body = String(body[..<end.lowerBound]) }
        return snippet(plainText(body))
    }
    static func approvedCover(_ text: String?) -> URL? {
        guard let text, text.utf8.count <= 4096, var parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme), let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil, parts.port == nil || [80,443].contains(parts.port!), ["qpic.cn","qlogo.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        parts.scheme = "https"; parts.port = nil; parts.fragment = nil
        return parts.url
    }
    static func localCover(_ record: ArticleRecord) -> URL? {
        guard let path = record.path else { return nil }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if let coverPath = record.coverPath {
            let file = URL(fileURLWithPath: coverPath).resolvingSymlinksInPath()
            if file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) { return file }
        }
        let source = root.appendingPathComponent("来源.json").resolvingSymlinksInPath()
        if source.path.hasPrefix(root.path + "/"), let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576, let data = try? Data(contentsOf: source), let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let cover = metadata["cover"] as? [String: Any], let relative = cover["path"] as? String {
            let url = root.appendingPathComponent(relative).resolvingSymlinksInPath()
            if url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
