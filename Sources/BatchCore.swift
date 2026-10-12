import Foundation
import Darwin

// 拾影 1.2 批量收集内核：纯 Foundation，不依赖 Store / SwiftUI / Quality / QQStyle。
// 接口形状取自 docs/batch-20261003/contract.md 第 18-25 行；主机白名单与链接规范化取自
// Backend/worker.py:28-40（input_link / id_from_url），本轮不联网、不展开短链、不做字幕或 AI 推断。

enum BatchError: Error, Equatable, LocalizedError {
    case emptyInput
    case textTooLarge(utf8Bytes: Int, limit: Int)
    case tooManyLinks(count: Int, limit: Int)
    case invalidCollectionName(String, reason: String)
    case collectionPathTooLong(utf8Bytes: Int, limit: Int)
    case parentFolderUnusable(String)
    case corruptedLibrary(path: String, reason: String)
    case refusedOverwriteCorrupted(path: String)
    case writeFailed(path: String, reason: String)
    case collectionPathMissing(String)
    case exportTargetExists(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "没有可导入的链接：请粘贴抖音分享文案、链接，或单独一行的 19 位作品 ID。"
        case .textTooLarge(let bytes, let limit):
            return "导入文本 \(bytes) 字节，超过 \(limit) 字节上限，请拆成多个文件分批导入。"
        case .tooManyLinks(let count, let limit):
            return "本次解析出 \(count) 条链接，超过 \(limit) 条上限，未做任何截断，请拆分后再导入。"
        case .invalidCollectionName(let name, let reason):
            return "收集名称「\(name)」不可用：\(reason)。"
        case .collectionPathTooLong(let bytes, let limit):
            return "收集名称过长（UTF-8 \(bytes) 字节，上限 \(limit) 字节），请缩短名称或换更浅的保存位置。"
        case .parentFolderUnusable(let path):
            return "所选收集位置不可用：\(path)。"
        case .corruptedLibrary(let path, let reason):
            return "资料库文件已损坏，未做任何修改：\(path)（\(reason)）。请先备份该文件再处理。"
        case .refusedOverwriteCorrupted(let path):
            return "资料库文件当前无法读取，已拒绝覆盖写入：\(path)。请先备份并修复或删除该文件。"
        case .writeFailed(let path, let reason):
            return "写入失败：\(path)（\(reason)）。"
        case .collectionPathMissing(let path):
            return "收集目录不存在，已停止导出：\(path)。"
        case .exportTargetExists(let path):
            return "导出目录已存在，已停止以免覆盖：\(path)。"
        }
    }
}

enum BatchLimits {
    static let maxTextBytes = 5 * 1024 * 1024
    static let maxLinks = 5000
    static let maxNameBytes = 180
    static let maxPathBytes = 1024
    static let sourceExcerptBytes = 4096
}

// MARK: - 状态与数据模型

enum BatchStatus: String, Codable {
    case pending, running, completed, failed, cancelled

    var title: String {
        switch self {
        case .pending:   return "等待中"
        case .running:   return "下载中"
        case .completed: return "已完成"
        case .failed:    return "失败"
        case .cancelled: return "已取消"
        }
    }
}

struct StudyCollection: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var notes: String = ""
    var parentID: UUID? = nil
    var createdAt: Date = Date()

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// 一次导入的完整原文只存这里一份（contract.md:29-31 大批量内存补充）：
/// 5000 条 × 5MiB 若逐 item 复制全文会膨胀到 25GiB，所以 item 只留摘录、全文按批存。
struct BatchImportSource: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var collectionID: UUID
    var text: String
    var createdAt: Date = Date()
    init(collectionID: UUID, text: String) {
        self.collectionID = collectionID
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        collectionID = try c.decode(UUID.self, forKey: .collectionID)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct BatchItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var collectionID: UUID
    var link: String
    /// 原始行的 UTF-8 前 4096 字节摘录，全文见 `BatchImportSource`（由 `importID` 指过去）。
    var sourceText: String
    var importID: UUID? = nil
    var qualityRaw: String = "highest"
    var status: BatchStatus = .pending
    var title: String = "等待解析"
    var author: String = ""
    var description: String = ""
    var videoID: String? = nil
    var platformRaw: String? = nil
    var path: String? = nil
    var mediaKind: String? = nil
    var imagePaths: [String]? = nil
    var isAlbum: Bool { mediaKind == "image_album" }
    /// 入队时快照下来的「同时导出配套音轨（M4A）」开关，默认开。真正的音轨提取归 B。
    var wantsAudio: Bool = true
    var audioPath: String? = nil
    var audioError: String? = nil
    var width: Int = 0
    var height: Int = 0
    var duration: Double = 0
    var bytes: Int64 = 0
    var error: String? = nil
    var createdAt: Date = Date()
    /// 博主采集入队时的扫描快照。缺键表示旧资料库或普通链接入队，解码为 nil。
    var creatorPublishedAt: Int64? = nil
    var creatorDiggCount: Int64? = nil
    var creatorCollectCount: Int64? = nil
    var creatorSourceURL: String? = nil

    init(collectionID: UUID, link: String, sourceText: String, qualityRaw: String = "highest") {
        self.collectionID = collectionID
        self.link = link
        self.sourceText = sourceText
        self.qualityRaw = qualityRaw
    }

    enum CodingKeys: String, CodingKey {
        case id, collectionID, link, sourceText, importID, qualityRaw, status, title, author, description
        case platformRaw, videoID, path, wantsAudio, audioPath, audioError, width, height, duration, bytes, error, createdAt
        case mediaKind, imagePaths
        case creatorPublishedAt, creatorDiggCount, creatorCollectCount, creatorSourceURL
    }

    /// 带默认值的字段一律按"缺键即取默认"解码：1.2 期间新增 wantsAudio/audioPath/audioError 时，
    /// 早先写下的库文件不会被整份判成损坏。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        collectionID = try c.decode(UUID.self, forKey: .collectionID)
        link = try c.decode(String.self, forKey: .link)
        sourceText = try c.decodeIfPresent(String.self, forKey: .sourceText) ?? ""
        importID = try c.decodeIfPresent(UUID.self, forKey: .importID)
        qualityRaw = try c.decodeIfPresent(String.self, forKey: .qualityRaw) ?? "highest"
        status = try c.decodeIfPresent(BatchStatus.self, forKey: .status) ?? .pending
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "等待解析"
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        videoID = try c.decodeIfPresent(String.self, forKey: .videoID)
        platformRaw = try c.decodeIfPresent(String.self, forKey: .platformRaw)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        mediaKind = try c.decodeIfPresent(String.self, forKey: .mediaKind)
        imagePaths = try c.decodeIfPresent([String].self, forKey: .imagePaths)
        wantsAudio = try c.decodeIfPresent(Bool.self, forKey: .wantsAudio) ?? true
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        audioError = try c.decodeIfPresent(String.self, forKey: .audioError)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        creatorPublishedAt = try c.decodeIfPresent(Int64.self, forKey: .creatorPublishedAt)
        creatorDiggCount = try c.decodeIfPresent(Int64.self, forKey: .creatorDiggCount)
        creatorCollectCount = try c.decodeIfPresent(Int64.self, forKey: .creatorCollectCount)
        creatorSourceURL = try c.decodeIfPresent(String.self, forKey: .creatorSourceURL)
    }

    var dimensions: String { width > 0 && height > 0 ? "\(width) × \(height)" : "" }
    var statusTitle: String { status.title }
}

struct BatchLibraryState: Codable, Equatable {
    var schemaVersion: Int = 1
    var collections: [StudyCollection] = []
    var items: [BatchItem] = []
    var imports: [BatchImportSource] = []

    /// 合成 decoder 会因为缺键判整库损坏；本轮新增过 imports，早先写下的库必须还能打开。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        collections = try c.decodeIfPresent([StudyCollection].self, forKey: .collections) ?? []
        items = try c.decodeIfPresent([BatchItem].self, forKey: .items) ?? []
        imports = try c.decodeIfPresent([BatchImportSource].self, forKey: .imports) ?? []
    }
}

struct BatchImportPreview: Equatable {
    var links: [String]
    var duplicateCount: Int
    var invalidCount: Int
    /// key = 规范化 link，value = 产出该 link 的首条原始行（UTF-8 前 4096 字节摘录）。
    var sourceTexts: [String: String] = [:]
}

// MARK: - 链接提取与规范化

enum BatchLinkParser {
    /// 与 Backend/worker.py:33 的白名单一致；hostname 精确匹配，
    /// 因此 douyin.com.evil.test、www.douyin.com.evil.test 一律拒绝。
    static let allowedHosts: Set<String> = [
        "v.douyin.com", "www.douyin.com", "douyin.com", "www.iesdouyin.com", "iesdouyin.com",
        "www.bilibili.com", "bilibili.com", "b23.tv", "space.bilibili.com",
        "www.xiaohongshu.com", "xiaohongshu.com", "xhslink.com", "www.xhslink.com",
        "channels.weixin.qq.com", "weixin.qq.com", "www.weixin.qq.com",
    ]

    private static let trailingJunk = CharacterSet(charactersIn: "，。！!；;）)")
    // ICU 不认 \u{...}，会把整个正则编译成 nil；这里直接嵌入表意空格字面量。
    private static let urlPattern = "https?://[^\\s<>\"\u{3000}]+"
    private static let bareIDPattern = "^\\s*(\\d{19})\\s*$"

    private static let regex: NSRegularExpression? = try? NSRegularExpression(pattern: urlPattern)
    private static let bareIDRegex: NSRegularExpression? = try? NSRegularExpression(pattern: bareIDPattern)

    static func preview(_ text: String, existing: Set<String> = []) throws -> BatchImportPreview {
        let bytes = text.utf8.count
        guard bytes <= BatchLimits.maxTextBytes else {
            throw BatchError.textTooLarge(utf8Bytes: bytes, limit: BatchLimits.maxTextBytes)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BatchError.emptyInput
        }

        var seen = existing
        var links: [String] = []
        var sources: [String: String] = [:]
        var duplicates = 0
        var invalid = 0
        var acceptable = 0

        for line in text.split(whereSeparator: \.isNewline) {
            let row = String(line)
            guard !row.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var acceptedInRow = 0
            for candidate in extract(row) {
                guard let canonical = normalize(candidate) else { continue }
                acceptedInRow += 1
                acceptable += 1
                if seen.contains(canonical) { duplicates += 1; continue }
                seen.insert(canonical)
                links.append(canonical)
                if sources[canonical] == nil { sources[canonical] = excerpt(row) }
                guard links.count <= BatchLimits.maxLinks else {
                    throw BatchError.tooManyLinks(count: links.count, limit: BatchLimits.maxLinks)
                }
            }
            if acceptedInRow == 0 { invalid += 1 }
        }

        // 全量重复不等于"没有链接"：这时返回空 links 并把 duplicateCount/invalidCount 交回去，
        // 界面才能说清"这些链接已在本主题里"，而不是被 emptyInput 掩盖（contract 末尾预览可见性补充）。
        guard acceptable > 0 else { throw BatchError.emptyInput }
        return BatchImportPreview(links: links, duplicateCount: duplicates, invalidCount: invalid, sourceTexts: sources)
    }

    /// 按 UTF-8 字节上限截取，且不切断字素簇；行内多链接时同一行原文会映射给每个链接。
    static func excerpt(_ text: String, limit: Int = BatchLimits.sourceExcerptBytes) -> String {
        guard text.utf8.count > limit else { return text }
        var end = text.startIndex
        var bytes = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let width = text[end..<next].utf8.count
            if bytes + width > limit { break }
            bytes += width
            end = next
        }
        return String(text[..<end])
    }

    /// 一行里可能夹着多条 URL（分享文案里带跳转链接），全部取出；再补一个独立 19 位 ID。
    private static func extract(_ row: String) -> [String] {
        let scoped = row.replacingOccurrences(of: "\\:", with: ":")
        var found: [String] = []
        if let regex {
            let range = NSRange(scoped.startIndex..<scoped.endIndex, in: scoped)
            regex.matches(in: scoped, range: range).forEach { match in
                guard let swift = Range(match.range, in: scoped) else { return }
                let trimmed = String(scoped[swift]).trimmingCharacters(in: trailingJunk)
                if !trimmed.isEmpty { found.append(trimmed) }
            }
        }
        if let bareIDRegex {
            let range = NSRange(scoped.startIndex..<scoped.endIndex, in: scoped)
            bareIDRegex.matches(in: scoped, range: range).forEach { match in
                guard match.numberOfRanges > 1, let swift = Range(match.range(at: 1), in: scoped) else { return }
                found.append(String(scoped[swift]))
            }
        }
        return found
    }

    /// 规范化：带 video/note 19 位 ID 的一律收成 https://www.douyin.com/video/ID；
    /// 短链保留 host+path 并去掉 query 与 fragment，等 worker 解析出 metadata 后再按 videoID 去重。
    static func normalize(_ candidate: String) -> String? {
        let bare = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if bare.count == 19, bare.allSatisfy(\.isNumber) {
            return "https://www.douyin.com/video/\(bare)"
        }
        guard let components = URLComponents(string: bare),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), allowedHosts.contains(host) else { return nil }
        let path = (components.path.isEmpty ? "/" : components.path).trimmingCharacters(in: trailingJunk)
        let platform = platformRaw(from: bare)
        if platform == "douyin", let id = videoID(fromPath: path) { return "https://www.douyin.com/video/\(id)" }
        var rebuilt = URLComponents()
        rebuilt.scheme = "https"; rebuilt.host = host; rebuilt.path = path
        switch platform {
        case "bilibili":
            if let id = videoID(from: bare) {
                let part = components.queryItems?.first(where: { $0.name == "p" })?.value.flatMap(Int.init)
                return "https://www.bilibili.com/video/\(id)" + (part.map { $0 > 0 ? "?p=\($0)" : "" } ?? "")
            }
            guard host == "b23.tv" else { return nil }
        case "xiaohongshu":
            guard host == "xhslink.com" || host == "www.xhslink.com" || videoID(from: bare) != nil else { return nil }
            // 分享签名参与平台访问，不能和追踪参数一起丢掉。
            rebuilt.percentEncodedQuery = components.percentEncodedQuery?.split(separator: "&").filter { ["xsec_token", "xsec_source"].contains(String($0.split(separator: "=", maxSplits: 1)[0])) }.joined(separator: "&")
        case "wechat":
            guard host == "channels.weixin.qq.com" || path.hasPrefix("/sph/") else { return nil }
            rebuilt.percentEncodedQuery = components.percentEncodedQuery
            rebuilt.fragment = components.fragment
        default: break
        }
        return rebuilt.url?.absoluteString
    }

    static func platformRaw(from link: String) -> String? {
        guard let host = URLComponents(string: link)?.host?.lowercased(), allowedHosts.contains(host) else { return nil }
        if host.contains("bilibili") || host == "b23.tv" { return "bilibili" }
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "xiaohongshu" }
        if host == "channels.weixin.qq.com" || host == "weixin.qq.com" || host == "www.weixin.qq.com" { return "wechat" }
        return "douyin"
    }

    static func videoID(from link: String) -> String? {
        guard let components = URLComponents(string: link), let platform = platformRaw(from: link) else { return nil }
        switch platform {
        case "bilibili":
            guard let match = components.path.range(of: #"/(?:video)/(BV[A-Za-z0-9]{10}|av[0-9]+)(?:/|$)"#, options: .regularExpression) else { return nil }
            return String(components.path[match]).split(separator: "/").last.map(String.init)
        case "xiaohongshu":
            guard let match = components.path.range(of: #"/(?:explore|discovery/item)/([A-Fa-f0-9]{24})(?:/|$)"#, options: .regularExpression) else { return nil }
            return String(components.path[match]).split(separator: "/").last.map(String.init)
        case "wechat":
            if let fragment = components.fragment, fragment.hasPrefix("shiying-capture-") {
                let id = String(fragment.dropFirst("shiying-capture-".count))
                return id.isEmpty ? nil : id
            }
            return nil
        default: return videoID(fromPath: components.path)
        }
    }

    static func identity(for link: String, videoID: String? = nil) -> String? {
        guard let platform = platformRaw(from: link) else { return nil }
        if let id = videoID ?? self.videoID(from: link), !id.isEmpty {
            let part = platform == "bilibili" ? URLComponents(string: link)?.queryItems?.first(where: { $0.name == "p" })?.value.flatMap(Int.init) : nil
            return platform + ":" + id + (part.map { $0 > 0 ? ":p\($0)" : "" } ?? "")
        }
        return normalize(link).map { platform + ":" + $0 }
    }

    private static func videoID(fromPath path: String) -> String? {
        guard let marker = path.range(of: #"/(?:video|note)/"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tail = path[marker.upperBound...].prefix(while: { $0.isNumber })
        // 比 worker.py:39 的正则更严：后面还跟着数字（20 位以上）视为不是合法作品 ID。
        return tail.count == 19 && tail.allSatisfy(\.isNumber) ? String(tail) : nil
    }
}

struct CollectionOrganizationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One atomic directory rename plus an atomic library update, with a durable recovery receipt.
struct CollectionMoveJournal: Codable {
    var version = 1
    let source: String
    let destination: String
    let before: Data
    let after: Data
    var historyBefore: Data? = nil
    var historyAfter: Data? = nil
}

struct CollectionRelocation: Equatable { let source: String; let destination: String }

enum CollectionOrganization {
    static func children(of parent: UUID?, in folders: [StudyCollection]) -> [StudyCollection] {
        folders.filter { $0.parentID == parent }
    }
    static func ancestors(of id: UUID?, in folders: [StudyCollection]) -> [StudyCollection] {
        var current = id, seen = Set<UUID>(), result: [StudyCollection] = []
        while let next = current, seen.insert(next).inserted,
              let folder = folders.first(where: { $0.id == next }) {
            result.insert(folder, at: 0); current = folder.parentID
        }
        return result
    }
    static func title(of folder: StudyCollection, in folders: [StudyCollection]) -> String {
        ancestors(of: folder.id, in: folders).map(\.name).joined(separator: " / ")
    }
    static func validateParent(_ parent: UUID?, for id: UUID?, in folders: [StudyCollection]) throws {
        guard let parent else { return }
        guard folders.contains(where: { $0.id == parent }) else {
            throw CollectionOrganizationError(message: "目标文件夹已不存在，请重新选择。")
        }
        if let id, ancestors(of: parent, in: folders).contains(where: { $0.id == id }) {
            throw CollectionOrganizationError(message: "不能把文件夹移到自己或自己的子文件夹中。")
        }
    }
    static func validate(_ folders: [StudyCollection]) throws {
        guard Set(folders.map(\.id)).count == folders.count else {
            throw CollectionOrganizationError(message: "文件夹标识重复，分类关系无法安全读取。")
        }
        for folder in folders { try validateParent(folder.parentID, for: folder.id, in: folders) }
    }
    static func reorder(_ id: UUID, by offset: Int, in folders: inout [StudyCollection]) {
        guard let index = folders.firstIndex(where: { $0.id == id }), offset == -1 || offset == 1 else { return }
        let siblings = folders.indices.filter { folders[$0].parentID == folders[index].parentID }
        guard let slot = siblings.firstIndex(of: index), siblings.indices.contains(slot + offset) else { return }
        folders.swapAt(index, siblings[slot + offset])
    }
    static func editedNotes(_ notes: String) throws -> String {
        guard notes.utf8.count <= 32 * 1024 else {
            throw CollectionOrganizationError(message: "备注超过32 KiB，请缩短后保存；原备注和输入内容保留。")
        }
        return notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func relocated(_ path: String, from source: String, to destination: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if path == source { return destination }
        if path.hasPrefix(source + "/") { return destination + path.dropFirst(source.count) }
        return path
    }
}

// MARK: - 持久化

struct BatchRepository {
    let rootURL: URL
    static let fileName = "batch-library.json"
    static let exportPrefix = "学习资料"
    /// Test-host injection only; the production App never sets this callback.
    static var collectionMoveFailureForTesting: ((String) throws -> Void)?

    init(rootURL: URL) { self.rootURL = rootURL }

    private var fileURL: URL { rootURL.appendingPathComponent(BatchRepository.fileName) }
    var moveJournalURL: URL { rootURL.appendingPathComponent("collection-move.json") }
    private var moveHistoryURL: URL { rootURL.deletingLastPathComponent().appendingPathComponent("history.json") }

    private static func renameWithoutOverwrite(_ source: String, _ destination: String) throws {
        guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            let explanation: String
            switch code {
            case EEXIST, ENOTEMPTY: explanation = "目标已有同名文件或文件夹，未覆盖。"
            case EXDEV: explanation = "源和目标位于不同磁盘；当前支持同一磁盘内移动，原目录未动。"
            case EACCES, EPERM: explanation = "没有移动此目录的权限。"
            case ENOENT: explanation = "源目录或目标父目录已不存在。"
            case ENOSPC: explanation = "磁盘空间不足。"
            default: explanation = "系统移动失败（errno \(code)）。"
            }
            throw CollectionOrganizationError(message: explanation + "源：\(source)；目标：\(destination)")
        }
    }

    func recoverCollectionMove() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: moveJournalURL.path) else { return }
        do {
            let journal = try Self.decoder.decode(CollectionMoveJournal.self, from: Data(contentsOf: moveJournalURL))
            guard journal.version == 1, journal.source.hasPrefix("/"), journal.destination.hasPrefix("/"),
                  journal.source != "/", journal.destination != "/", journal.source != journal.destination,
                  (journal.historyBefore == nil) == (journal.historyAfter == nil) else { throw CollectionOrganizationError(message: "移动恢复记录格式无效。") }
            let prior = try Self.decoder.decode(BatchLibraryState.self, from: journal.before)
            let next = try Self.decoder.decode(BatchLibraryState.self, from: journal.after)
            try CollectionOrganization.validate(prior.collections); try CollectionOrganization.validate(next.collections)
            guard let original = prior.collections.first(where: { $0.path == journal.source }),
                  next.collections.contains(where: { $0.id == original.id && $0.path == journal.destination }) else {
                throw CollectionOrganizationError(message: "恢复记录与原文件夹身份不匹配。")
            }
            let current = try Data(contentsOf: fileURL)
            let history = try journal.historyBefore.map { _ in try Data(contentsOf: moveHistoryURL) }
            guard (current == journal.before || current == journal.after),
                  journal.historyBefore == nil || history == journal.historyBefore || history == journal.historyAfter else {
                throw CollectionOrganizationError(message: "资料库或单条记录已被另行修改，未自动覆盖。")
            }
            let sourceExists = fm.fileExists(atPath: journal.source), destinationExists = fm.fileExists(atPath: journal.destination)
            let allCommitted = current == journal.after && (journal.historyAfter == nil || history == journal.historyAfter)
            if allCommitted && destinationExists && !sourceExists {
                try fm.removeItem(at: moveJournalURL); return
            }
            if !sourceExists && destinationExists {
                try Self.renameWithoutOverwrite(journal.destination, journal.source)
            } else if !(sourceExists && !destinationExists) {
                throw CollectionOrganizationError(message: "源和目标目录状态不一致，未覆盖。源：\(journal.source)；目标：\(journal.destination)")
            }
            if current != journal.before { try journal.before.write(to: fileURL, options: .atomic) }
            if let original = journal.historyBefore, history != original { try original.write(to: moveHistoryURL, options: .atomic) }
            try fm.removeItem(at: moveJournalURL)
        } catch {
            throw CollectionOrganizationError(message: "文件夹移动恢复未完成：\(error.localizedDescription)。移动记录保留在\(moveJournalURL.path)，当前资料库不再写入。")
        }
    }

    func moveCollection(_ id: UUID, to parent: UUID?, rootDirectory: URL, expected: BatchLibraryState) throws -> BatchLibraryState {
        try CollectionOrganization.validateParent(parent, for: id, in: expected.collections)
        guard let index = expected.collections.firstIndex(where: { $0.id == id }) else {
            throw CollectionOrganizationError(message: "要移动的文件夹已不存在。")
        }
        guard try load() == expected else { throw CollectionOrganizationError(message: "资料库已经变化，未移动目录，请重新打开App后重试。") }
        let fm = FileManager.default
        let source = URL(fileURLWithPath: expected.collections[index].path).standardizedFileURL
        let target = parent.flatMap { id in expected.collections.first { $0.id == id }.map { URL(fileURLWithPath: $0.path) } } ?? rootDirectory
        let destination = target.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        let sourceReal = source.resolvingSymlinksInPath().path, targetReal = target.resolvingSymlinksInPath().path
        guard !(targetReal == sourceReal || targetReal.hasPrefix(sourceReal + "/")) else {
            throw CollectionOrganizationError(message: "目标真实目录在源文件夹内部，不能移入自己或自己的子目录。")
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CollectionOrganizationError(message: "源不是可直接移动的真实文件夹（目录链接不支持移动）。")
        }
        guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CollectionOrganizationError(message: "目标父目录不可用，原目录未动。")
        }
        var next = expected
        next.collections[index].parentID = parent
        for i in next.collections.indices {
            next.collections[i].path = CollectionOrganization.relocated(next.collections[i].path, from: source.path, to: destination.path)
        }
        for i in next.items.indices {
            if let path = next.items[i].path { next.items[i].path = CollectionOrganization.relocated(path, from: source.path, to: destination.path) }
            if let path = next.items[i].audioPath { next.items[i].audioPath = CollectionOrganization.relocated(path, from: source.path, to: destination.path) }
            next.items[i].imagePaths = next.items[i].imagePaths?.map { CollectionOrganization.relocated($0, from: source.path, to: destination.path) }
        }
        try CollectionOrganization.validate(next.collections)
        if source.path == destination.path { try save(next); return next }
        guard !fm.fileExists(atPath: destination.path) else {
            throw CollectionOrganizationError(message: "目标已存在同名目录，未覆盖任何文件：\(destination.path)。请先选择其他目标。")
        }
        let before = try Data(contentsOf: fileURL), after = try Self.encoder.encode(next)
        var journal = CollectionMoveJournal(source: source.path, destination: destination.path, before: before, after: after)
        if fm.fileExists(atPath: moveHistoryURL.path) {
            let data = try Data(contentsOf: moveHistoryURL)
            guard var rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw CollectionOrganizationError(message: "单条下载记录格式无效，未移动目录。请先修复history.json。")
            }
            var changed = false
            for i in rows.indices {
                for key in ["folder", "path"] {
                    if let path = rows[i][key] as? String {
                        let updated = CollectionOrganization.relocated(path, from: source.path, to: destination.path)
                        if updated != path { rows[i][key] = updated; changed = true }
                    }
                }
                if let paths = rows[i]["imagePaths"] as? [String] {
                    let updated = paths.map { CollectionOrganization.relocated($0, from: source.path, to: destination.path) }
                    if updated != paths { rows[i]["imagePaths"] = updated; changed = true }
                }
            }
            if changed { journal.historyBefore = data; journal.historyAfter = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) }
        }
        let temporary = rootURL.appendingPathComponent(".move-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: try Self.encoder.encode(journal), attributes: [.posixPermissions: 0o600]) else {
            throw CollectionOrganizationError(message: "写入移动恢复记录失败，原目录未动。")
        }
        try fm.moveItem(at: temporary, to: moveJournalURL)
        do {
            try Self.renameWithoutOverwrite(source.path, destination.path)
            try Self.collectionMoveFailureForTesting?("afterDirectoryRename")
            // External edits detected here must not be overwritten during commit.
            guard try Data(contentsOf: fileURL) == before else { throw CollectionOrganizationError(message: "移动期间资料库被修改，停止提交。") }
            if let original = journal.historyBefore, try Data(contentsOf: moveHistoryURL) != original {
                throw CollectionOrganizationError(message: "移动期间单条下载记录被修改，停止提交。")
            }
            try after.write(to: fileURL, options: .atomic)
            try Self.collectionMoveFailureForTesting?("afterLibraryWrite")
            if let updated = journal.historyAfter { try updated.write(to: moveHistoryURL, options: .atomic) }
        } catch {
            let issue = error.localizedDescription
            do {
                try recoverCollectionMove()
                if try Data(contentsOf: fileURL) == after { return next }
            } catch {
                throw CollectionOrganizationError(message: "移动未完成：\(issue)。回滚也失败：\(error.localizedDescription)。源：\(source.path)；目标：\(destination.path)；恢复记录：\(moveJournalURL.path)。请保留目录并重新打开App。")
            }
            throw CollectionOrganizationError(message: "文件夹未移动，已恢复原位置：\(issue)")
        }
        // If cleanup fails, the coherent after-state is recognized on the next load.
        try? fm.removeItem(at: moveJournalURL)
        return next
    }

    func load() throws -> BatchLibraryState {
        try recoverCollectionMove()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return BatchLibraryState() }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw BatchError.corruptedLibrary(path: fileURL.path, reason: error.localizedDescription) }
        do {
            let state = try BatchRepository.decoder.decode(BatchLibraryState.self, from: data)
            try CollectionOrganization.validate(state.collections)
            return state
        }
        catch { throw BatchError.corruptedLibrary(path: fileURL.path, reason: String(describing: error)) }
    }

    func save(_ state: BatchLibraryState) throws {
        try recoverCollectionMove()
        try CollectionOrganization.validate(state.collections)
        // 先确认现存文件仍可解析，否则拒绝写入：损坏库不能被"保存"悄悄清成空库。
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { _ = try BatchRepository.decoder.decode(BatchLibraryState.self, from: Data(contentsOf: fileURL)) }
            catch { throw BatchError.refusedOverwriteCorrupted(path: fileURL.path) }
        }
        let data: Data
        do { data = try BatchRepository.encoder.encode(state) }
        catch { throw BatchError.writeFailed(path: fileURL.path, reason: String(describing: error)) }
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch { throw BatchError.writeFailed(path: fileURL.path, reason: error.localizedDescription) }
    }

    /// 日期用 Foundation 默认的 deferredToDate（Double 秒）落盘：逐位无损，
    /// save→load 后 item 仍可用 == 比较。人类可读时间只出现在 CSV 的入队时间列。
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }

    // MARK: 收集目录

    static func validateCollectionName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BatchError.invalidCollectionName(name, reason: "名称不能为空")
        }
        if trimmed == "." || trimmed == ".." {
            throw BatchError.invalidCollectionName(name, reason: "不能用 . 或 .. 作为目录名")
        }
        for scalar in trimmed.unicodeScalars {
            if scalar == "/" || scalar == "\\" {
                throw BatchError.invalidCollectionName(name, reason: "不能包含路径分隔符 / 或 \\")
            }
            if scalar.value < 0x20 || scalar.value == 0x7F {
                throw BatchError.invalidCollectionName(name, reason: "不能包含控制字符")
            }
        }
        guard trimmed.utf8.count <= BatchLimits.maxNameBytes else {
            throw BatchError.collectionPathTooLong(utf8Bytes: trimmed.utf8.count, limit: BatchLimits.maxNameBytes)
        }
        return trimmed
    }

    /// 在 parent 下创建真实子目录；重名时自动加唯一后缀，绝不覆盖或挪动已有内容。
    static func createCollection(name: String, parent: URL, existing: [StudyCollection]) throws -> StudyCollection {
        let safe = try validateCollectionName(name)
        let taken = Set(existing.map { $0.path.lowercased() })
        let fm = FileManager.default
        var isDir = ObjCBool(false)
        if fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue == false {
            throw BatchError.parentFolderUnusable(parent.path)
        }
        do { try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw BatchError.parentFolderUnusable("\(parent.path)（\(error.localizedDescription)）") }

        var candidateName = safe
        var index = 2
        while true {
            let url = parent.appendingPathComponent(candidateName)
            if url.path.utf8.count > BatchLimits.maxPathBytes {
                throw BatchError.collectionPathTooLong(utf8Bytes: url.path.utf8.count, limit: BatchLimits.maxPathBytes)
            }
            if taken.contains(url.path.lowercased()) || fm.fileExists(atPath: url.path) {
                candidateName = "\(safe)-\(index)"
                index += 1
                continue
            }
            do { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
            catch { throw BatchError.writeFailed(path: url.path, reason: error.localizedDescription) }
            return StudyCollection(name: candidateName, path: url.path)
        }
    }

    // MARK: 元数据索引导出
    // 音轨裁决（contract.md:3-11）取消学习包后，这里只保留基础 CSV/JSON 索引：
    // 不生成 Markdown 总览、不生成分析提示词、不重复落全文原文。

    /// 在 collection 目录内新建一个「学习资料-时间-UUID」目录，只写 CSV/JSON 索引；
    /// 不覆盖任何旧导出，不改动集合里已有的视频与音轨文件。
    static func export(collection: StudyCollection, items: [BatchItem], imports: [BatchImportSource] = []) throws -> URL {
        let fm = FileManager.default
        var isDir = ObjCBool(false)
        guard fm.fileExists(atPath: collection.path, isDirectory: &isDir), isDir.boolValue == true else {
            throw BatchError.collectionPathMissing(collection.path)
        }
        let dir = collectionDirectoryURL(for: collection)
        let target = dir.appendingPathComponent("\(BatchRepository.exportPrefix)-\(stamp(Date()))-\(UUID().uuidString.prefix(8))")
        guard !fm.fileExists(atPath: target.path) else { throw BatchError.exportTargetExists(target.path) }
        do { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
        catch { throw BatchError.writeFailed(path: target.path, reason: error.localizedDescription) }

        let scoped = items.filter { $0.collectionID == collection.id }
        let scopedImports = imports.filter { $0.collectionID == collection.id }
        let files: [(String, String)] = [
            ("资料.csv", csv(items: scoped)),
            ("资料.json", jsonString(collection: collection, items: scoped, imports: scopedImports)),
        ]
        for (name, body) in files {
            let url = target.appendingPathComponent(name)
            do { try body.data(using: .utf8)?.write(to: url, options: .atomic) }
            catch { throw BatchError.writeFailed(path: url.path, reason: error.localizedDescription) }
        }
        return target
    }

    private static func collectionDirectoryURL(for collection: StudyCollection) -> URL {
        URL(fileURLWithPath: collection.path, isDirectory: true)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// JSON 里只给导入批次的元信息索引，全文仍只在 `BatchLibraryState.imports` 存一份。
    private struct ImportIndex: Codable {
        let id: UUID
        let collectionID: UUID
        let createdAt: Date
        let utf8Bytes: Int
        let itemCount: Int
    }

    private struct Index: Codable {
        let schemaVersion: Int
        let exportedAt: Date
        let collection: StudyCollection
        let items: [BatchItem]
        let importIndex: [ImportIndex]
    }

    private static func jsonString(collection: StudyCollection, items: [BatchItem], imports: [BatchImportSource]) -> String {
        let index = Index(
            schemaVersion: 1,
            exportedAt: Date(),
            collection: collection,
            items: items,
            importIndex: imports.map { source in
                ImportIndex(id: source.id, collectionID: source.collectionID, createdAt: source.createdAt,
                              utf8Bytes: source.text.utf8.count, itemCount: items.filter { $0.importID == source.id }.count)
            }
        )
        guard let data = try? BatchRepository.encoder.encode(index), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func csv(items: [BatchItem]) -> String {
        let header = ["序号", "状态", "标题", "作者", "链接", "作品ID", "画质请求", "分辨率", "时长秒", "大小字节",
                      "本地路径", "音轨开关", "音轨路径", "音轨错误", "错误", "入队时间", "公开描述", "原始行摘录", "原文批次"]
        var rows = [header]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for (index, item) in items.enumerated() {
            rows.append([
                String(index + 1), item.status.rawValue, item.title, item.author, item.link, item.videoID ?? "",
                item.qualityRaw, item.dimensions, item.duration > 0 ? String(format: "%.1f", item.duration) : "",
                item.bytes > 0 ? String(item.bytes) : "", item.path ?? "", item.wantsAudio ? "开" : "关",
                item.audioPath ?? "", item.audioError ?? "", item.error ?? "",
                formatter.string(from: item.createdAt), item.description, item.sourceText, item.importID?.uuidString ?? "",
            ])
        }
        // BOM 让 Excel 按 UTF-8 打开中文，不加会被当成本地代码页。
        return "\u{FEFF}" + rows.map { cells in cells.map(escapeCSV).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func escapeCSV(_ field: String) -> String {
        // 表格公式保护：以 = + - @ 制表 回车 开头的文本会被 Excel/Sheets 当公式执行，先加单引号。
        let guarded: String
        if let first = field.first, "=+-@\t\r".contains(first) { guarded = "'" + field }
        else { guarded = field }
        let needsQuotes = guarded.contains(",") || guarded.contains("\"") || guarded.contains("\n") || guarded.contains("\r")
            || guarded != guarded.trimmingCharacters(in: .whitespaces)
        let doubled = guarded.replacingOccurrences(of: "\"", with: "\"\"")
        return needsQuotes ? "\"\(doubled)\"" : doubled
    }
}
