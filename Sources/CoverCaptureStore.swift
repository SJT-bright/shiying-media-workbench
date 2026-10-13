import Foundation
import AppKit
import Combine
import Darwin
import ImageIO
import CryptoKit

struct CoverCaptureFailure: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
}

/// Covers remain owned temporary images until every image is published and one
/// history transaction accepts all records. No video or login data is requested.
@MainActor final class CoverCaptureStore: ObservableObject {
    static var workerOverrideURL: URL?
    static var dataRootOverride: URL?

    @Published private(set) var draftRecords: [Record] = []
    @Published private(set) var busy = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    @Published private(set) var failures: [CoverCaptureFailure] = []
    @Published private(set) var totalCount = 0
    private(set) var frozenSourceURL = ""
    var hasDrafts: Bool { !draftRecords.isEmpty }
    var canConfirm: Bool { hasDrafts && !busy && !saving && failures.isEmpty && cleanupIssue == nil && !closing }

    private struct Entry {
        let job: PhotoDraftJob
        var record: Record
        let digest: String
    }
    fileprivate struct WorkerOutput {
        let path: String
        let paths: [String]
        let width: Int
        let height: Int
        let bytes: Int64
    }
    private struct CleanupOutput {
        let retained: [PhotoDraftJob]
        let issues: [String]
    }

    private let repository: PhotoDraftRepository
    private var jobs: [PhotoDraftJob] = []
    private var entries: [Entry] = []
    private var confirmedPaths = Set<String>()
    private var operationTask: Task<Void, Never>?
    private var publicationTask: Task<[PhotoPublication], Error>?
    private var activeWorker: CoverCaptureWorker?
    private var token = UUID()
    private var discardRequested = false
    private var cleanupIssue: String?
    private var recoveryIssue: String?
    private var closing = false
    private var terminationCompletions: [() -> Void] = []
    private var discardCompletions: [(Bool) -> Void] = []

    init() {
        let testBase = Self.dataRootOverride ?? shiyingTestDataRoot(fallback: "/tmp/shiying-cover-test-data")
        let base = testBase ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/拾影")
        let temporary = testBase?.appendingPathComponent("cover-previews")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent((Bundle.main.bundleIdentifier ?? "com.local.shiying") + ".cover-previews")
        repository = PhotoDraftRepository(root: temporary)
        let readable: Set<String>?
        do {
            let records = try HistoryRepository<Record>(fileURL: base.appendingPathComponent("history.json")).load()
            readable = Set(records.filter { $0.status == "完成" }.compactMap(\.path))
            confirmedPaths = readable ?? []
        } catch { readable = nil }
        do { try repository.recoverAbandoned(confirmed: readable) }
        catch {
            cleanupIssue = error.localizedDescription
            recoveryIssue = error.localizedDescription
            self.error = "上次临时封面清理未完成：\(error.localizedDescription)"
        }
    }

    func begin(posts: [CreatorPost], sourceURL: String, quality: Quality, folder: String) {
        guard !busy, !saving, !closing else { return }
        guard recoveryIssue == nil else {
            error = "上次临时封面存在未解决的保存事务，已保留相关文件。请先按提示位置修复后重新打开拾影：\(recoveryIssue!)"; return
        }
        guard !posts.isEmpty else { error = "请先选择要采集封面的作品。"; return }
        let executable = Self.workerOverrideURL ?? Bundle.main.resourceURL?.appendingPathComponent("worker/拾影Worker")
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            error = "下载组件缺失，请重新安装 App。"; return
        }
        let operation = UUID()
        token = operation
        busy = true; saving = false; discardRequested = false; error = nil; message = "正在临时下载封面…"
        failures = []; totalCount = posts.count; frozenSourceURL = sourceURL
        let previous = jobs, repository = repository, confirmed = confirmedPaths
        operationTask = Task {
            let cleanup = await Task.detached(priority: .utility) {
                Self.cleanup(previous, repository: repository, confirmed: confirmed)
            }.value
            guard token == operation else { return }
            applyCleanup(cleanup)
            entries = []; draftRecords = []
            if cleanupIssue != nil {
                error = "上次临时封面未能清理：\(cleanupIssue!)"
            } else {
                for post in posts {
                    if Task.isCancelled || discardRequested { break }
                    do {
                        guard let cover = post.cover, !cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw PhotoDraftError(message: "平台没有提供封面，未下载该作品。")
                        }
                        let input: [String: Any] = ["id": post.id, "title": post.title, "author": post.author,
                                                  "description": post.title, "link": post.link, "cover": cover]
                        let data = try JSONSerialization.data(withJSONObject: input)
                        guard data.count <= 64 * 1024 else { throw PhotoDraftError(message: "该作品的封面信息超过 64 KiB，未截断或下载。") }
                        let job = try repository.create()
                        jobs.append(job)
                        let inputURL = job.directory.appendingPathComponent("input.json")
                        try data.write(to: inputURL, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
                        if Task.isCancelled || discardRequested { break }
                        let worker = try CoverCaptureWorker(executable: executable, input: inputURL, folder: job.directory)
                        activeWorker = worker
                        let result = await Task.detached(priority: .userInitiated) { worker.collect() }.value
                        activeWorker = nil
                        if Task.isCancelled || discardRequested { break }
                        let output = try result.get()
                        let digest = try await Task.detached(priority: .userInitiated) {
                            try repository.validate(job, album: output.path, paths: output.paths)
                            return try Self.validatePixels(output)
                        }.value
                        if Task.isCancelled || discardRequested { break }
                        var record = Record(title: post.title, author: post.author, link: post.link, quality: quality,
                                            folder: folder, status: "待确认保存")
                        record.path = output.path; record.imagePaths = output.paths; record.mediaKind = "video_cover"
                        record.description = post.title; record.videoID = post.id
                        record.width = output.width; record.height = output.height; record.bytes = output.bytes
                        entries.append(Entry(job: job, record: record, digest: digest))
                        draftRecords.append(record)
                        message = "已临时下载 \(draftRecords.count)/\(posts.count) 张封面，失败 \(failures.count) 项。"
                    } catch {
                        if !Task.isCancelled && !discardRequested {
                            failures.append(CoverCaptureFailure(id: post.id, title: post.title, message: error.localizedDescription))
                        }
                    }
                }
                if !failures.isEmpty {
                    error = "\(failures.count) 项封面采集失败，尚未确认保存。\n" + failures.map {
                        "\($0.title.isEmpty ? $0.id : $0.title)：\($0.message)"
                    }.joined(separator: "\n")
                } else if !discardRequested && !Task.isCancelled {
                    message = "\(draftRecords.count) 张封面已临时下载，可复制后确认保存或取消保存。"
                }
            }
            if discardRequested || Task.isCancelled { await cleanupCurrent(cancelMessage: true) }
            finish(operation)
        }
    }

    func confirm(destination: String, commit: @escaping ([Record]) -> Bool, completion: @escaping (Bool) -> Void) {
        guard canConfirm else {
            if !failures.isEmpty { error = "部分封面未下载成功，未确认保存。请取消后重新采集。" }
            completion(false); return
        }
        let operation = UUID(), pending = entries, repository = repository
        token = operation; busy = true; saving = true; discardRequested = false; error = nil
        message = "正在确认保存 \(pending.count) 张封面…"
        let publishing = Task.detached(priority: .userInitiated) {
            var output: [PhotoPublication] = []
            for entry in pending {
                if Task.isCancelled { throw CancellationError() }
                guard let album = entry.record.path else { throw PhotoDraftError(message: "临时封面不完整，请重新采集。") }
                let expected = WorkerOutput(path: album, paths: entry.record.imagePaths ?? [], width: entry.record.width,
                                            height: entry.record.height, bytes: entry.record.bytes)
                try repository.validate(entry.job, album: album, paths: expected.paths)
                do {
                    guard try Self.validatePixels(expected) == entry.digest else {
                        throw PhotoDraftError(message: "图片字节与下载时不一致。")
                    }
                } catch {
                    throw PhotoDraftError(message: "临时封面被外部修改或不再完整，未确认保存：\(album)；\(error.localizedDescription)")
                }
                let published = try repository.publish(entry.job, album: album, paths: expected.paths,
                                                       destination: destination, cancelled: { Task.isCancelled })
                let copied = WorkerOutput(path: published.directory.path, paths: published.paths,
                                          width: expected.width, height: expected.height, bytes: expected.bytes)
                guard try Self.validatePixels(copied) == entry.digest else {
                    throw PhotoDraftError(message: "封面发布期间内容发生变化，未确认保存：\(published.directory.path)")
                }
                output.append(published)
            }
            return output
        }
        publicationTask = publishing
        operationTask = Task {
            var committed = false
            do {
                let publications = try await publishing.value
                if Task.isCancelled || discardRequested { throw CancellationError() }
                let now = Date()
                let records = zip(pending, publications).map { entry, publication -> Record in
                    var record = entry.record
                    record.path = publication.directory.path; record.imagePaths = publication.paths
                    record.folder = destination; record.date = now; record.status = "完成"
                    return record
                }
                guard commit(records) else {
                    throw PhotoDraftError(message: "封面记录保存失败，本次未确认保存；临时封面仍可复制。")
                }
                // History now owns all publications. Cancellation after this point
                // can only clean temporary files; it cannot roll back saved images.
                committed = true
                confirmedPaths.formUnion(publications.map { $0.directory.path })
                entries = []; draftRecords = []
                let issues = await Task.detached(priority: .utility) {
                    publications.compactMap { publication -> String? in
                        do { try repository.finalize(publication); return nil }
                        catch { return error.localizedDescription }
                    }
                }.value
                jobs.removeAll { !FileManager.default.fileExists(atPath: $0.directory.path) }
                message = "\(records.count) 张封面已保存。"
                if !issues.isEmpty {
                    cleanupIssue = issues.joined(separator: "\n")
                    error = "封面已保存，临时缓存清理未完成：\(cleanupIssue!)"
                }
            } catch {
                let rollbackIssues = await Task.detached(priority: .utility) {
                    pending.compactMap { entry -> String? in
                        do { try repository.rollbackCopies(entry.job); return nil }
                        catch { return error.localizedDescription }
                    }
                }.value
                if !rollbackIssues.isEmpty {
                    cleanupIssue = rollbackIssues.joined(separator: "\n")
                    self.error = "封面保存回滚未完成，已保留异常目录：\(cleanupIssue!)"
                } else if !discardRequested && !Task.isCancelled { self.error = error.localizedDescription }
                if discardRequested || Task.isCancelled { await cleanupCurrent(cancelMessage: true) }
            }
            finish(operation)
            completion(committed)
        }
    }

    func discard(completion: ((Bool) -> Void)? = nil) {
        if let completion { discardCompletions.append(completion) }
        discardRequested = true
        if busy {
            operationTask?.cancel(); publicationTask?.cancel(); activeWorker?.stop()
            message = "正在取消并清理临时封面…"
            return
        }
        let operation = UUID(); token = operation; busy = true
        operationTask = Task {
            await cleanupCurrent(cancelMessage: true)
            finish(operation)
        }
    }

    func copy(_ record: Record) {
        guard let actual = draftRecords.first(where: { $0.id == record.id }), let path = actual.imagePaths?.first else { return }
        do {
            try ShiyingPhotoClipboard.copy(path: path)
            message = "封面已复制，可直接粘贴；取消保存不会影响剪贴板。"
        } catch { self.error = error.localizedDescription }
    }

    func shutdown(completion: (() -> Void)? = nil) {
        closing = true
        if let completion { terminationCompletions.append(completion) }
        discard()
    }

    private func cleanupCurrent(cancelMessage: Bool) async {
        let pending = jobs, repository = repository, confirmed = confirmedPaths
        let cleanup = await Task.detached(priority: .utility) {
            Self.cleanup(pending, repository: repository, confirmed: confirmed)
        }.value
        applyCleanup(cleanup)
        let retained = Set(jobs.map(\.id))
        entries.removeAll { !retained.contains($0.job.id) }
        draftRecords = entries.map(\.record)
        if let recoveryIssue {
            cleanupIssue = recoveryIssue
            error = "上次临时封面保存事务尚未解决，已保留：\(recoveryIssue)"
        } else if cleanup.issues.isEmpty {
            error = nil; failures = []
            if cancelMessage { message = "临时封面已清理，已复制的图片仍可粘贴。" }
        } else { error = "临时封面清理未完成，已保留异常目录：\(cleanup.issues.joined(separator: "\n"))" }
    }

    private func applyCleanup(_ cleanup: CleanupOutput) {
        jobs = cleanup.retained
        cleanupIssue = cleanup.issues.isEmpty ? nil : cleanup.issues.joined(separator: "\n")
    }

    nonisolated private static func cleanup(_ jobs: [PhotoDraftJob], repository: PhotoDraftRepository,
                                           confirmed: Set<String>) -> CleanupOutput {
        var retained: [PhotoDraftJob] = [], issues: [String] = []
        for job in jobs {
            guard FileManager.default.fileExists(atPath: job.directory.path) else { continue }
            do { try repository.discard(job, confirmed: confirmed) }
            catch { retained.append(job); issues.append(error.localizedDescription) }
        }
        return CleanupOutput(retained: retained, issues: issues)
    }

    nonisolated private static func validatePixels(_ output: WorkerOutput) throws -> String {
        guard let path = output.paths.first else { throw PhotoDraftError(message: "临时封面不完整。") }
        let file = URL(fileURLWithPath: path)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 64 * 1024 * 1024, Int64(size) == output.bytes,
              output.width <= 80_000_000, output.height <= 80_000_000,
              Int64(output.width) * Int64(output.height) <= 80_000_000 else {
            throw PhotoDraftError(message: "封面文件的尺寸或字节信息不一致，请重新采集。")
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == size,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              ["public.jpeg", "public.png", "org.webmproject.webp", "com.compuserve.gif"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == output.width,
              properties[kCGImagePropertyPixelHeight] as? Int == output.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == output.width, image.height == output.height else {
            throw PhotoDraftError(message: "封面文件未完整解码，或尺寸、类型、字节信息不一致，请重新采集。")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func finish(_ operation: UUID) {
        guard token == operation else { return }
        activeWorker = nil; operationTask = nil; publicationTask = nil
        busy = false; saving = false; discardRequested = false
        let discarded = discardCompletions; discardCompletions = []
        let cleared = jobs.isEmpty && cleanupIssue == nil && recoveryIssue == nil
        discarded.forEach { $0(cleared) }
        if closing {
            let callbacks = terminationCompletions; terminationCompletions = []
            callbacks.forEach { $0() }
        }
    }
}

/// The main actor owns one worker. Pipe consumption never retains stderr or
/// grows stdout beyond a small event budget, and cleanup waits for actual exit.
private final class CoverCaptureWorker: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private let lock = NSLock()
    private var stopping = false

    init(executable: URL, input: URL, folder: URL) throws {
        process.executableURL = executable
        process.arguments = ["cover", "--input", input.path, "--folder", folder.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = diagnostics
        try process.run()
    }

    func stop() {
        lock.lock()
        let shouldStop = !stopping; stopping = true
        lock.unlock()
        guard shouldStop else { return }
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func collect() -> Result<CoverCaptureStore.WorkerOutput, Error> {
        DispatchQueue.global(qos: .utility).async { [diagnostics] in
            while !diagnostics.fileHandleForReading.availableData.isEmpty {}
            try? diagnostics.fileHandleForReading.close()
        }
        var buffer = Data(), total = 0, complete: [String: Any]?, failure: String?, completionCount = 0, rejectedOutput = false
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if rejectedOutput { continue }
            total += chunk.count
            if total > 2 * 1024 * 1024 || buffer.count + chunk.count > 256 * 1024 {
                rejectedOutput = true
                failure = "封面组件输出超限，已停止本次下载。"; stop(); buffer.removeAll(); continue
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    failure = "封面组件返回了无效数据。"; stop(); continue
                }
                switch event["event"] as? String {
                case "complete": completionCount += 1; complete = event
                case "error": failure = String((event["message"] as? String ?? "封面下载失败。").prefix(4_096))
                case "cancelled": failure = "封面下载已取消。"
                default: break
                }
            }
        }
        try? output.fileHandleForReading.close()
        process.waitUntilExit()
        if !buffer.isEmpty && failure == nil { failure = "封面组件返回了不完整数据。" }
        if let failure { return .failure(PhotoDraftError(message: failure)) }
        guard process.terminationStatus == 0, completionCount == 1, let event = complete,
              event["mediaKind"] as? String == "video_cover", let path = event["path"] as? String,
              let paths = event["imagePaths"] as? [String], paths.count == 1,
              let width = event["width"] as? Int, width > 0,
              let height = event["height"] as? Int, height > 0,
              let bytes = (event["bytes"] as? NSNumber)?.int64Value, bytes > 0 else {
            return .failure(PhotoDraftError(message: "封面未完整下载，请重新采集。"))
        }
        return .success(CoverCaptureStore.WorkerOutput(path: path, paths: paths, width: width, height: height, bytes: bytes))
    }
}
