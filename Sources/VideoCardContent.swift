import Foundation

/// 只整理展示字段；原始标题和简介仍保留在下载记录中。
struct VideoCardContent {
    let title: String
    let description: String
    let tags: [String]

    init(title sourceTitle: String, description sourceDescription: String?) {
        let sourceDescription = sourceDescription ?? ""
        let hashtag = try! NSRegularExpression(pattern: "[#＃]([\\p{L}\\p{N}_][\\p{L}\\p{N}_.-]*)")
        var seen = Set<String>()
        var collected: [String] = []
        for source in [sourceDescription, sourceTitle] {
            let range = NSRange(source.startIndex..., in: source)
            for match in hashtag.matches(in: source, range: range) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let tag = String(source[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
                if !tag.isEmpty, seen.insert(tag.lowercased()).inserted { collected.append(tag) }
            }
        }
        tags = Array(collected.prefix(5))
        func withoutTags(_ source: String) -> String {
            hashtag.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func singleLine(_ source: String) -> String {
            source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let cleanedTitle = singleLine(withoutTags(sourceTitle))
        title = cleanedTitle.isEmpty ? "未命名作品" : cleanedTitle
        var lines = withoutTags(sourceDescription).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // 平台常把标题重复在简介第一行，仅移除完全相同的这行。
        if let first = lines.first, singleLine(first) == cleanedTitle { lines.removeFirst() }
        description = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
