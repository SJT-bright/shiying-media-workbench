import Foundation

struct SingleLinkParseResult: Equatable {
    let links: [String]
    let duplicateCount: Int
    /// Number of URL candidates that the supported-platform parser rejected.
    /// Ordinary sharing text and blank lines are not URL candidates.
    let unsupportedCount: Int
}

enum SingleLinkParseError: Error, Equatable, LocalizedError {
    case emptyInput
    case textTooLarge(utf8Bytes: Int, limit: Int)
    case tooManyLinks(count: Int, limit: Int)
    case noSupportedLinks(unsupportedCount: Int)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "请粘贴作品链接或完整分享文案，可以一次粘贴多条。"
        case .textTooLarge(let bytes, let limit):
            return "本次输入 \(bytes) 字节，超过 \(limit) 字节上限，请分批粘贴。"
        case .tooManyLinks(let count, let limit):
            return "本次识别到 \(count) 条不同链接，超过 \(limit) 条上限，未开始解析，请分批粘贴。"
        case .noSupportedLinks(let count):
            if count > 0 {
                return "本次 \(count) 条链接均不支持，请粘贴抖音、哔哩哔哩、小红书或视频号的作品分享链接。"
            }
            return "没有识别到作品链接，请粘贴完整分享链接或文案。"
        }
    }
}

/// Input-only parsing for the vertically ordered cards on 新建下载.
/// It does not expand short URLs, request metadata, create tasks, or touch storage.
enum SingleLinkParser {
    static let maxLinks = 200
    static let maxTextBytes = 5 * 1024 * 1024

    // Share text frequently places Chinese punctuation directly between URLs.
    // Keep ASCII query punctuation intact so platform signatures are preserved.
    // A full outer URL stays one candidate even when its query/fragment embeds
    // another URL; an untrusted host cannot smuggle an accepted inner URL.
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"[a-z][a-z0-9+.-]*://[^\s<>"'，。！；（）【】《》「」『』“”‘’、　]+"#,
        options: [.caseInsensitive]
    )
    // Match the existing worker's compatibility path for schemeless Douyin URLs.
    // The boundary prevents a substring of a different host becoming a new URL.
    private static let bareDouyinRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}@/.-])(?:v\.douyin\.com|www\.douyin\.com|douyin\.com|www\.iesdouyin\.com|iesdouyin\.com)/[^\s<>"'，。！；（）【】《》「」『』“”‘’、　]+"#,
        options: [.caseInsensitive]
    )
    private static let bareIDRegex = try! NSRegularExpression(pattern: #"^[0-9]{19}$"#)
    private static let trailingJunk = CharacterSet(charactersIn: "),;!]}>'\".,")

    static func parse(_ text: String) throws -> SingleLinkParseResult {
        let bytes = text.utf8.count
        guard bytes <= maxTextBytes else {
            throw SingleLinkParseError.textTooLarge(utf8Bytes: bytes, limit: maxTextBytes)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SingleLinkParseError.emptyInput
        }

        var links: [String] = []
        var seen = Set<String>()
        var duplicateCount = 0
        var unsupportedCount = 0

        for row in text.split(whereSeparator: \.isNewline) {
            let scoped = String(row).replacingOccurrences(of: "\\:", with: ":")
            let range = NSRange(scoped.startIndex..<scoped.endIndex, in: scoped)
            let fullMatches = urlRegex.matches(in: scoped, range: range)
            var candidates: [(offset: Int, link: String)] = fullMatches.compactMap { match in
                guard let swiftRange = Range(match.range, in: scoped) else { return nil }
                return (match.range.location, trimTail(String(scoped[swiftRange])))
            }

            for match in bareDouyinRegex.matches(in: scoped, range: range) {
                // A scheme URL, including a refused URL, owns its whole span.
                guard !fullMatches.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }),
                      let swiftRange = Range(match.range, in: scoped) else { continue }
                candidates.append((match.range.location, "https://" + trimTail(String(scoped[swiftRange]))))
            }

            if candidates.isEmpty {
                let bare = scoped.trimmingCharacters(in: .whitespacesAndNewlines)
                let bareRange = NSRange(bare.startIndex..<bare.endIndex, in: bare)
                if bareIDRegex.firstMatch(in: bare, range: bareRange) != nil {
                    candidates.append((0, bare))
                }
            }

            for candidate in candidates.sorted(by: { $0.offset < $1.offset }) {
                // Reuse the existing source of truth for exact host checking,
                // credentials/ports, platform paths, and signed query handling.
                guard let normalized = BatchLinkParser.normalize(candidate.link) else {
                    unsupportedCount += 1
                    continue
                }
                if seen.insert(normalized).inserted {
                    links.append(normalized)
                } else {
                    duplicateCount += 1
                }
            }
        }

        // Check after the complete bounded input has been inspected. Over-limit
        // input returns no partial list and the diagnostic uses the actual count.
        guard links.count <= maxLinks else {
            throw SingleLinkParseError.tooManyLinks(count: links.count, limit: maxLinks)
        }
        guard !links.isEmpty else {
            throw SingleLinkParseError.noSupportedLinks(unsupportedCount: unsupportedCount)
        }
        return SingleLinkParseResult(links: links, duplicateCount: duplicateCount, unsupportedCount: unsupportedCount)
    }

    private static func trimTail(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous..<end].unicodeScalars.allSatisfy(trailingJunk.contains) else { break }
            end = previous
        }
        return String(text[..<end])
    }
}
