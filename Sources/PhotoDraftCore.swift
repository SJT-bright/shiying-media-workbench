import Foundation
import Darwin
import CryptoKit

struct PhotoDraftError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PhotoDraftJob: Equatable {
    let id: UUID
    let directory: URL
}

struct PhotoPublication {
    let job: PhotoDraftJob
    let directory: URL
    let paths: [String]
}

/// Only UUID directories carrying our ownership marker are disposable.
/// Confirmation copies into an exclusive destination; a journal distinguishes saved files after a crash.
struct PhotoDraftRepository {
    let root: URL
    private let fm = FileManager.default
    private static let marker = ".shiying-photo-owner"
    private struct Journal: Codable {
        var id: UUID
        var staging: String
        var published: String?
        var names: [String]
        var hashes: [String]
    }

    init(root: URL) {
        // macOS /var and /tmp are aliases. Resolve an existing ancestor before
        // appending a new directory, so enumeration and ownership checks agree.
        var ancestor = root.standardizedFileURL, missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.insert(ancestor.lastPathComponent, at: 0); ancestor.deleteLastPathComponent()
        }
        let physical = realpath(ancestor.path, nil)
        var resolved = physical.map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) } ?? ancestor
        if let physical { free(physical) }
        for component in missing { resolved.appendPathComponent(component, isDirectory: true) }
        self.root = resolved
    }

    private func fail(_ message: String) -> PhotoDraftError { PhotoDraftError(message: message) }
    private func physicalPath(_ url: URL) -> String {
        guard let path = realpath(url.path, nil) else { return url.path }
        defer { free(path) }; return String(cString: path)
    }
    private func directory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
    private func mark(_ directory: URL, id: UUID) throws {
        try Data(id.uuidString.utf8).write(to: directory.appendingPathComponent(Self.marker), options: .atomic)
    }
    private func marked(_ directory: URL, id: UUID) -> Bool {
        self.directory(directory) && (try? String(contentsOf: directory.appendingPathComponent(Self.marker), encoding: .utf8)) == id.uuidString
    }
    private func owned(_ job: PhotoDraftJob) -> Bool {
        directory(root) && physicalPath(job.directory.deletingLastPathComponent()) == physicalPath(root)
            && job.directory.lastPathComponent == job.id.uuidString && marked(job.directory, id: job.id)
    }
    private func exclusiveDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func create() throws -> PhotoDraftJob {
        if !fm.fileExists(atPath: root.path) { try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        guard directory(root) else { throw fail("临时图片目录不可用，请重新打开拾影。") }
        let id = UUID(), url = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try exclusiveDirectory(url)
        do { try mark(url, id: id) } catch { try? fm.removeItem(at: url); throw error }
        return PhotoDraftJob(id: id, directory: url)
    }
    func validate(_ job: PhotoDraftJob, album: String, paths: [String]) throws {
        guard owned(job), !paths.isEmpty, paths.count <= 500 else { throw fail("临时图文不完整，请重新解析。") }
        let albumURL = URL(fileURLWithPath: album).standardizedFileURL
        guard physicalPath(albumURL.deletingLastPathComponent()) == physicalPath(job.directory), directory(albumURL) else { throw fail("图片目录不属于本次临时下载，未处理其中的文件。") }
        let members = try fm.contentsOfDirectory(atPath: albumURL.path)
        guard Set(members) == Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent }), members.count == paths.count else { throw fail("临时图片内容发生变化，请重新解析。") }
        for (index, path) in paths.enumerated() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard physicalPath(url.deletingLastPathComponent()) == physicalPath(albumURL), values.isRegularFile == true, values.isSymbolicLink != true,
                (values.fileSize ?? 0) > 0, (values.fileSize ?? 0) <= 64 * 1024 * 1024,
                url.deletingPathExtension().lastPathComponent == String(format: "%03d", index + 1),
                ["jpg", "png", "webp", "gif"].contains(url.pathExtension.lowercased()) else { throw fail("临时图片路径或文件无效，请重新解析。") }
        }
    }
    private func digest(_ path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
    private func write(_ journal: Journal, job: PhotoDraftJob) throws {
        try JSONEncoder().encode(journal).write(to: job.directory.appendingPathComponent("save.json"), options: .atomic)
    }
    private func exclusiveRename(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, 4) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func publish(_ job: PhotoDraftJob, album: String, paths: [String], destination: String,
                 cancelled: () -> Bool = { false }) throws -> PhotoPublication {
        try validate(job, album: album, paths: paths)
        let parent = URL(fileURLWithPath: destination).standardizedFileURL.resolvingSymlinksInPath()
        guard directory(parent), fm.isWritableFile(atPath: parent.path), physicalPath(parent) != physicalPath(root), !physicalPath(parent).hasPrefix(physicalPath(root) + "/") else { throw fail("保存位置不存在、不可写或属于临时缓存，请更换保存位置。") }
        let stage = parent.appendingPathComponent(".shiying-confirm-" + job.id.uuidString, isDirectory: true)
        var journal = Journal(id: job.id, staging: stage.path, names: paths.map { URL(fileURLWithPath: $0).lastPathComponent }, hashes: [])
        try write(journal, job: job)
        try exclusiveDirectory(stage)
        do { try mark(stage, id: job.id) } catch { try? fm.removeItem(at: stage); throw error }
        let copied = stage.appendingPathComponent("album", isDirectory: true)
        do {
            try exclusiveDirectory(copied); try mark(copied, id: job.id)
            for path in paths {
                if cancelled() { throw CancellationError() }
                let output = copied.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                try fm.copyItem(atPath: path, toPath: output.path)
                let original = try digest(path), copiedHash = try digest(output.path)
                guard original == copiedHash else { throw fail("图片复制校验失败，临时原图仍保留。") }
                journal.hashes.append(copiedHash)
            }
            let name = URL(fileURLWithPath: album).lastPathComponent
            for suffix in 0..<10_000 {
                if cancelled() { throw CancellationError() }
                let output = parent.appendingPathComponent(name + (suffix == 0 ? "" : "_\(suffix)"), isDirectory: true)
                journal.published = output.path; try write(journal, job: job)
                do { try exclusiveRename(copied, output) }
                catch let error as POSIXError where error.code == .EEXIST { continue }
                let result = PhotoPublication(job: job, directory: output, paths: journal.names.map { output.appendingPathComponent($0).path })
                try fm.removeItem(at: stage)
                return result
            }
            throw fail("同名图文目录过多，请更换保存位置。")
        } catch {
            if marked(stage, id: job.id) { try? fm.removeItem(at: stage) }
            throw error
        }
    }
    private func cleanPublished(_ journal: Journal, confirmed: Set<String>?) throws {
        guard let path = journal.published else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard marked(url, id: journal.id) else { return }
        guard let confirmed else { throw fail("下载记录尚不可读，未清理待确认保存目录：\(path)") }
        if confirmed.contains(path) { try fm.removeItem(at: url.appendingPathComponent(Self.marker)); return }
        guard journal.names.count == journal.hashes.count,
            Set(try fm.contentsOfDirectory(atPath: path)) == Set(journal.names + [Self.marker]) else { throw fail("待确认目录内容发生变化，已保留：\(path)") }
        for (name, hash) in zip(journal.names, journal.hashes) {
            let image = url.appendingPathComponent(name)
            let values = try image.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, try digest(image.path) == hash else { throw fail("待确认图片被外部修改，已保留：\(path)") }
        }
        try fm.removeItem(at: url)
    }
    func discard(_ job: PhotoDraftJob, confirmed: Set<String> = []) throws {
        try recover(job, confirmed: confirmed)
    }
    func finalize(_ publication: PhotoPublication) throws {
        try recover(publication.job, confirmed: [publication.directory.path])
    }
    func rollbackCopies(_ job: PhotoDraftJob) throws {
        guard owned(job) else { throw fail("临时图片的所有权标记不匹配，未删除未知文件。") }
        let file = job.directory.appendingPathComponent("save.json")
        guard fm.fileExists(atPath: file.path) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
        let staging = URL(fileURLWithPath: journal.staging).standardizedFileURL
        guard journal.id == job.id, staging.lastPathComponent == ".shiying-confirm-" + job.id.uuidString,
            journal.published.map({ URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent() == staging.deletingLastPathComponent() }) ?? true,
            journal.names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." && $0 != Self.marker }) else { throw fail("临时保存事务不匹配，文件已保留。") }
        try cleanPublished(journal, confirmed: [])
        if marked(staging, id: job.id) { try fm.removeItem(at: staging) }
        try fm.removeItem(at: file)
    }
    private func recover(_ job: PhotoDraftJob, confirmed: Set<String>?) throws {
        guard owned(job) else { throw fail("临时图片的所有权标记不匹配，未删除未知文件：\(job.directory.path)") }
        let file = job.directory.appendingPathComponent("save.json")
        if fm.fileExists(atPath: file.path) {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
            let staging = URL(fileURLWithPath: journal.staging).standardizedFileURL
            guard journal.id == job.id, staging.lastPathComponent == ".shiying-confirm-" + job.id.uuidString,
                journal.published.map({ URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent() == staging.deletingLastPathComponent() }) ?? true,
                journal.names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." && $0 != Self.marker }) else { throw fail("临时保存事务无效，文件已保留：\(file.path)") }
            try cleanPublished(journal, confirmed: confirmed)
            if marked(staging, id: job.id) { try fm.removeItem(at: staging) }
        }
        try fm.removeItem(at: job.directory)
    }
    func recoverAbandoned(confirmed: Set<String>?) throws {
        guard fm.fileExists(atPath: root.path) else { return }
        guard directory(root) else { throw fail("临时图片根目录无效，未进行清理。") }
        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent), marked(url, id: id) else { continue }
            try recover(PhotoDraftJob(id: id, directory: url), confirmed: confirmed)
        }
    }
}
