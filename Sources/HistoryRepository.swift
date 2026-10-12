import Foundation

/// 原生验收可指定独立资料根；只有显式 --test-mode 才生效。
func shiyingTestDataRoot(fallback: String) -> URL? {
    let args = CommandLine.arguments
    guard args.contains("--test-mode") else { return nil }
    if let i = args.firstIndex(of: "--test-data-root"), args.indices.contains(i + 1), args[i + 1].hasPrefix("/") {
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }
    return URL(fileURLWithPath: fallback, isDirectory: true)
}

/// 与旧 history.json 格式兼容。读取和写入失败必须交给界面，不能把坏文件当作空记录。
struct HistoryRepository<Entry: Codable> {
    let fileURL: URL
    var backupURL: URL { fileURL.deletingPathExtension().appendingPathExtension("backup.json") }

    func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))
    }

    func save(_ entries: [Entry]) throws {
        let data = try JSONEncoder().encode(entries)
        // 每次写入前重新核验现存记录；启动之后被损坏的文件也不能被覆盖。
        var previous: Data?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let existing = try Data(contentsOf: fileURL)
            _ = try JSONDecoder().decode([Entry].self, from: existing)
            previous = existing
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 只备份确认可读取的旧记录；备份失败时同样保留主文件。
        if let previous { try previous.write(to: backupURL, options: .atomic) }
        try data.write(to: fileURL, options: .atomic)
    }
}
