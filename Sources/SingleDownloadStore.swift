import Foundation
import AppKit
import Combine

enum Quality: String, CaseIterable, Identifiable, Codable {
    case compact = "480", balanced = "720", original = "highest"
    var id: String { rawValue }
    var title: String { switch self { case .compact: return "480P"; case .balanced: return "720P"; case .original: return "最高画质" } }
    var detail: String { switch self { case .compact: return "轻巧保存 · 节省空间"; case .balanced: return "清晰流畅 · 日常观看"; case .original: return "保留细节 · 原始视频源" } }
    var icon: String { switch self { case .compact: return "leaf"; case .balanced: return "play.rectangle"; case .original: return "sparkles.tv" } }
}
struct PhotoPreview: Codable {
    let url: String
    let width: Int?
    let height: Int?
}

struct Video: Codable {
    var id: String; var title: String; var author: String; var duration: Double
    var width: Int; var height: Int; var size: Int64; var cover: String?
    var description: String? = nil
    var mediaKind: String? = nil
    var images: [PhotoPreview]? = nil
    var isAlbum: Bool { mediaKind == "image_album" }
    var dimensions: String { width > 0 && height > 0 ? "\(width) × \(height)" : "尺寸待核验" }
    var time: String { duration.isFinite && duration > 0 ? String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) : "时长待核验" }
}
struct Record: Codable, Identifiable {
    var id = UUID(); var date = Date(); var title: String; var author: String
    var link: String; var quality: Quality; var folder: String
    var path: String?; var width = 0; var height = 0; var bytes: Int64 = 0
    var status: String; var error: String?
    var description: String? = nil
    var videoID: String? = nil
    var mediaKind: String? = nil
    var imagePaths: [String]? = nil
    var isAlbum: Bool { mediaKind == "image_album" }
}
func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

@MainActor final class Store: ObservableObject {
    static var workerOverrideURL: URL?
    static var dataRootOverride: URL?
    @Published var text = ""
    @Published var quality: Quality = .original { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var folder: String { didSet { defaults.set(folder, forKey: "folder") } }
    @Published var choosingFolder = false
    @Published var viewingAlbum: Record?
    @Published var albumInitialIndex = 0
    @Published var photoDraft: Record?
    @Published var photoMessage: String?
    @Published private(set) var savingPhoto = false
    @Published var page = "新建下载" {
        didSet { if oldValue == "新建下载" && page != oldValue && previewJob != nil { cancelPhotoSave() } }
    }
    @Published var video: Video?
    @Published var busy = false
    @Published var downloading = false
    @Published var cancelling = false
    @Published var stage = ""
    @Published var detail = ""
    @Published var fraction: Double = 0
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var speed: Double = 0
    @Published var error: String?
    @Published var result: Record?
    @Published var records: [Record] = []
    @Published var historyIssue: String?
    @Published var historyUnavailable = false
    @Published var search = ""
    @Published var filter = "全部"
    @Published var revealOnComplete: Bool { didSet { defaults.set(revealOnComplete, forKey: "reveal") } }
    private var defaults: UserDefaults { CommandLine.arguments.contains("--test-mode") || Self.dataRootOverride != nil ? UserDefaults(suiteName: "com.local.shiying.testing")! : .standard }
    private var process: Process?
    private var token = UUID()
    private var currentRecord: Record?
    private var parsedText = ""
    private let historyURL: URL
    private let photoRepository: PhotoDraftRepository
    private var historyWritable = true
    private enum Purpose { case preview, videoDownload }
    private var purpose = Purpose.preview
    private var previewJob: PhotoDraftJob?
    private var previewComplete: [String: Any]?
    private var downloadVideoAfterPreview = false
    private var photoCleanupIssue: String?
    private var publishingTask: Task<PhotoPublication, Error>?
    private var saveTask: Task<Void, Never>?
    private var terminationCompletion: (() -> Void)?

    init() {
        let testing = CommandLine.arguments.contains("--test-mode") || Self.dataRootOverride != nil
        let d = testing ? UserDefaults(suiteName: "com.local.shiying.testing")! : UserDefaults.standard
        folder = d.string(forKey: "folder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        quality = Quality(rawValue: d.string(forKey: "quality") ?? "highest") ?? .original
        revealOnComplete = d.bool(forKey: "reveal")
        let testBase = Self.dataRootOverride ?? shiyingTestDataRoot(fallback: "/tmp/shiying-ui-test-data")
        let base = testBase ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/拾影")
        let temporary = testBase?.appendingPathComponent("photo-previews")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent((Bundle.main.bundleIdentifier ?? "com.local.shiying") + ".photo-previews")
        photoRepository = PhotoDraftRepository(root: temporary)
        if testing {
            let downloads = base.appendingPathComponent("videos")
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            folder = d.string(forKey: "folder") ?? downloads.path
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        historyURL = base.appendingPathComponent("history.json")
        do {
            try BatchRepository(rootURL: base.appendingPathComponent("batch")).recoverCollectionMove()
            records = try HistoryRepository<Record>(fileURL: historyURL).load()
        } catch {
            historyWritable = false; historyUnavailable = true
            historyIssue = "下载记录读取失败，原文件已保留，本次不会覆盖。新记录仅保留在本次窗口；请先备份并修复记录文件。原因：\(error.localizedDescription)"
        }
        do { try photoRepository.recoverAbandoned(confirmed: historyUnavailable ? nil : Set(completed.compactMap(\.path))) }
        catch { photoCleanupIssue = error.localizedDescription; self.error = "上次临时图文清理未完成：\(error.localizedDescription)" }
        if let i = CommandLine.arguments.firstIndex(of: "--prefill"), CommandLine.arguments.indices.contains(i + 1) { text = CommandLine.arguments[i + 1] }
    }
    var completed: [Record] { records.filter { $0.status == "完成" } }
    var filtered: [Record] { records.filter { (filter == "全部" || $0.status == filter) && (search.isEmpty || ($0.title + $0.author).localizedCaseInsensitiveContains(search)) } }
    var overall: Double { switch stage { case "download": return 0.08 + fraction * 0.55; case "export": return 0.63 + fraction * 0.32; case "verify": return 0.95 + fraction * 0.04; default: return 0.03 } }
    var photoPaths: [String] { photoDraft?.imagePaths ?? (result?.isAlbum == true ? result?.imagePaths : nil) ?? [] }
    var hasLiveChild: Bool { process?.isRunning ?? false }
    @discardableResult func save() -> Bool {
        guard historyWritable else { return false }
        do { try HistoryRepository<Record>(fileURL: historyURL).save(records); return true }
        catch {
            historyWritable = false
            historyIssue = "下载记录写入失败，已保留原文件。请检查磁盘和记录文件，再重新打开拾影。原因：\(error.localizedDescription)"
            return false
        }
    }
    func openHistoryFolder() { NSWorkspace.shared.open(historyURL.deletingLastPathComponent()) }
    func reloadHistoryAfterFolderRecovery() {
        guard !busy, historyWritable else { return }
        do { records = try HistoryRepository<Record>(fileURL: historyURL).load() }
        catch { historyIssue = "移动恢复后读取下载记录失败，原文件保留：\(error.localizedDescription)" }
    }
    func applyCollectionRelocation(_ move: CollectionRelocation) {
        for i in records.indices {
            if let path = records[i].path { records[i].path = CollectionOrganization.relocated(path, from: move.source, to: move.destination) }
            records[i].folder = CollectionOrganization.relocated(records[i].folder, from: move.source, to: move.destination)
            records[i].imagePaths = records[i].imagePaths?.map { CollectionOrganization.relocated($0, from: move.source, to: move.destination) }
        }
        if var value = result {
            if let path = value.path { value.path = CollectionOrganization.relocated(path, from: move.source, to: move.destination) }
            value.folder = CollectionOrganization.relocated(value.folder, from: move.source, to: move.destination)
            value.imagePaths = value.imagePaths?.map { CollectionOrganization.relocated($0, from: move.source, to: move.destination) }; result = value
        }
        folder = CollectionOrganization.relocated(folder, from: move.source, to: move.destination)
    }
    func paste() { if let value = NSPasteboard.general.string(forType: .string) { text = value; inputChanged() } }
    func chooseFolder() { guard !busy else { return }; choosingFolder = true }
    func preview() { startPreview(downloadVideo: false) }
    func download() {
        guard !busy else { return }
        if photoDraft != nil { confirmPhotoSave() }
        else if video?.isAlbum == false && parsedText == text { start(isDownload: true) }
        else { startPreview(downloadVideo: true) }
    }
    private func startPreview(downloadVideo: Bool) {
        guard !busy else { return }
        guard cleanupPreview() else { return }
        if let issue = photoCleanupIssue { error = issue; return }
        do { previewJob = try photoRepository.create() }
        catch { self.error = "临时图片目录创建失败：\(error.localizedDescription)"; return }
        downloadVideoAfterPreview = downloadVideo
        start(isDownload: false)
        if !busy { _ = cleanupPreview() }
    }
    func retry(_ r: Record) { guard !busy else { return }; text = r.link; quality = r.quality; folder = r.folder; page = "新建下载"; video = nil; download() }
    func cancel() {
        guard busy else { return }
        cancelling = true; detail = "正在取消并清理临时文件…"
        if savingPhoto { publishingTask?.cancel(); saveTask?.cancel() }
        else if let p = process, p.isRunning { p.terminate() }
    }
    @discardableResult private func cleanupPreview() -> Bool {
        guard let job = previewJob else { photoDraft = nil; return true }
        do { try photoRepository.discard(job); previewJob = nil; photoDraft = nil; return true }
        catch { photoCleanupIssue = error.localizedDescription; self.error = "临时图片未能清理：\(error.localizedDescription)"; return false }
    }
    func cancelPhotoSave() {
        if busy { if purpose == .preview || savingPhoto { cancel() }; return }
        viewingAlbum = nil
        guard cleanupPreview() else { return }
        video = nil; result = nil; parsedText = ""; error = nil
        photoMessage = "临时图片已清理，已复制的图片仍可粘贴。"
    }
    func copyPhoto(_ index: Int) {
        let paths = photoPaths
        guard paths.indices.contains(index) else { return }
        do { try ShiyingPhotoClipboard.copy(path: paths[index]); photoMessage = "第 \(index + 1) 张图片已复制，可直接粘贴。" }
        catch { self.error = error.localizedDescription }
    }
    func confirmPhotoSave() {
        guard !busy, let draft = photoDraft, let job = previewJob, let album = draft.path else { return }
        guard historyWritable else { error = "下载记录不可写，图片仍为临时预览。请先修复记录，或复制后取消保存。"; return }
        busy = true; savingPhoto = true; cancelling = false; error = nil; photoMessage = nil; viewingAlbum = nil
        stage = "export"; fraction = 0; detail = "正在确认保存图片…"
        let repository = photoRepository, destination = folder, paths = draft.imagePaths ?? []
        let operation = Task.detached(priority: .userInitiated) {
            try repository.publish(job, album: album, paths: paths, destination: destination, cancelled: { Task.isCancelled })
        }
        publishingTask = operation
        saveTask = Task {
            do {
                let published = try await operation.value
                if Task.isCancelled || cancelling { throw CancellationError() }
                var record = draft; record.path = published.directory.path; record.imagePaths = published.paths
                record.folder = destination; record.date = Date(); record.status = "完成"
                records.insert(record, at: 0)
                guard save() else { records.removeAll { $0.id == record.id }; throw PhotoDraftError(message: "记录保存失败，本次图片未确认保存，临时图片仍可复制。") }
                // From this point the formal record owns these files; cleanup must preserve them.
                do { try repository.finalize(published); previewJob = nil }
                catch { photoCleanupIssue = error.localizedDescription; self.error = "图片已保存，临时缓存清理未完成：\(error.localizedDescription)"; previewJob = nil }
                photoDraft = nil; result = record; detail = "\(paths.count) 张图片已保存"; fraction = 1
                if revealOnComplete { reveal(record) }
            } catch {
                do { try repository.rollbackCopies(job) }
                catch { photoCleanupIssue = error.localizedDescription; self.error = "保存回滚未完成：\(error.localizedDescription)" }
                if cancelling || Task.isCancelled {
                    if cleanupPreview() { video = nil; parsedText = ""; photoMessage = "临时图片已清理，已复制的图片仍可粘贴。" }
                } else if self.error == nil { self.error = error.localizedDescription }
            }
            busy = false; savingPhoto = false; cancelling = false; publishingTask = nil; saveTask = nil
            if let completion = terminationCompletion { terminationCompletion = nil; _ = cleanupPreview(); completion() }
        }
    }
    func shutdown(completion: (() -> Void)? = nil) {
        if savingPhoto { terminationCompletion = completion; cancel(); return }
        token = UUID()
        if let process, process.isRunning { process.terminate() }
        _ = cleanupPreview()
        completion?()
    }
    func discardPhotoPreviewForClosedWindow() {
        guard previewJob != nil else { return }
        cancelPhotoSave()
    }
    func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
    func reveal(_ r: Record) { if let path = r.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
    func play(_ r: Record, initialIndex: Int = 0) { if r.isAlbum { albumInitialIndex = initialIndex; viewingAlbum = r } else if let path = r.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
    func remove(_ r: Record) { let previous = records; records.removeAll { $0.id == r.id }; if !save() { records = previous } }
    func clearFailed() { let previous = records; records.removeAll { $0.status != "完成" }; if !save() { records = previous } }
    func inputChanged() {
        if !busy && parsedText != text {
            viewingAlbum = nil
            guard cleanupPreview() else { return }
            video = nil; result = nil; error = nil; photoMessage = nil
        }
    }
    private func start(isDownload: Bool) {
        guard !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let executable = Self.workerOverrideURL ?? Bundle.main.resourceURL?.appendingPathComponent("worker/拾影Worker")
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { error = "下载组件缺失，请重新安装 App。"; return }
        if isDownload && !FileManager.default.isWritableFile(atPath: folder) { error = "保存位置不可写，请重新选择文件夹。"; return }
        busy = true; downloading = isDownload; cancelling = false; error = nil; result = nil; photoDraft = nil; photoMessage = nil; fraction = 0; stage = "parse"; detail = "正在解析作品链接"; received = 0; speed = 0
        purpose = isDownload ? .videoDownload : .preview; previewComplete = nil
        let job = UUID(); token = job; let input = text
        currentRecord = isDownload ? Record(title: video?.title ?? "视频下载", author: video?.author ?? "", link: input, quality: quality, folder: folder, status: "处理中") : nil
        let p = Process(); p.executableURL = executable
        p.arguments = [isDownload ? "download" : "info", "--link", input]
        if isDownload { p.arguments! += ["--quality", quality.rawValue, "--folder", folder, "--video-only"] }
        else if let previewJob { p.arguments! += ["--preview-images", "--folder", previewJob.directory.path] }
        let stdout = Pipe(); let stderr = Pipe(); p.standardOutput = stdout; p.standardError = stderr
        let session = CreatorStore.sessionForDownload(link: input); let sessionPipe = session.map { _ in Pipe() }
        if let sessionPipe { p.arguments! += ["--session-stdin"]; p.standardInput = sessionPipe }
        process = p
        do { try p.run() } catch { busy = false; downloading = false; process = nil; self.error = "下载组件启动失败：\(error.localizedDescription)"; return }
        if let session, let sessionPipe {
            DispatchQueue.global(qos: .utility).async {
                defer { try? sessionPipe.fileHandleForWriting.close() }
                do { try sessionPipe.fileHandleForWriting.write(contentsOf: session) }
                catch { if p.isRunning { p.terminate() } }
            }
        }
        DispatchQueue.global(qos: .utility).async { _ = stderr.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { self.handle(event, job: job, input: input) }
                    }
                }
            }
            p.waitUntilExit()
            DispatchQueue.main.async { self.finish(job: job, code: p.terminationStatus) }
        }
    }
    private func handle(_ event: [String: Any], job: UUID, input: String) {
        guard token == job else { return }
        switch event["event"] as? String {
        case "metadata":
            if let data = try? JSONSerialization.data(withJSONObject: event), let info = try? JSONDecoder().decode(Video.self, from: data) {
                video = info; parsedText = input; currentRecord?.title = info.title; currentRecord?.author = info.author
                currentRecord?.description = info.description; currentRecord?.videoID = info.id; currentRecord?.mediaKind = info.mediaKind
                if info.isAlbum && purpose == .preview { downloading = true; detail = "图文已识别，正在临时下载图片…" }
            }
        case "progress":
            if !cancelling { detail = event["detail"] as? String ?? "处理中"; stage = event["stage"] as? String ?? "parse"; fraction = min(1, max(0, event["progress"] as? Double ?? 0)) }
            received = (event["received"] as? NSNumber)?.int64Value ?? received; total = (event["total"] as? NSNumber)?.int64Value ?? total; speed = event["speed"] as? Double ?? speed
        case "complete":
            if purpose == .preview { previewComplete = event; return }
            if var r = currentRecord {
                r.path = event["path"] as? String; r.width = event["width"] as? Int ?? 0; r.height = event["height"] as? Int ?? 0; r.bytes = (event["bytes"] as? NSNumber)?.int64Value ?? 0; r.status = "完成"
                r.mediaKind = event["mediaKind"] as? String ?? r.mediaKind; r.imagePaths = event["imagePaths"] as? [String]
                if var info = video {
                    info.width = r.width; info.height = r.height; info.size = r.bytes
                    if let duration = event["duration"] as? Double, duration.isFinite, duration > 0 { info.duration = duration }
                    video = info
                }
                records.insert(r, at: 0); save(); result = r; currentRecord = nil; detail = "视频已保存"; fraction = 1
                if revealOnComplete { reveal(r) }
            }
        case "error": error = event["message"] as? String ?? "下载失败，请重试。"
        case "cancelled": cancelling = true
        default: break
        }
    }
    private func finish(job: UUID, code: Int32) {
        guard token == job else { return }
        let wasPreview = purpose == .preview
        if wasPreview, !cancelling, code == 0, error == nil, let info = video, info.isAlbum,
            let event = previewComplete, event["mediaKind"] as? String == "image_album", let previewJob,
            let path = event["path"] as? String, let paths = event["imagePaths"] as? [String] {
            do {
                try photoRepository.validate(previewJob, album: path, paths: paths)
                var record = Record(title: info.title, author: info.author, link: parsedText, quality: quality, folder: folder, status: "待确认保存")
                record.path = path; record.imagePaths = paths; record.mediaKind = "image_album"; record.videoID = info.id
                record.description = info.description; record.width = event["width"] as? Int ?? info.width; record.height = event["height"] as? Int ?? info.height
                record.bytes = (event["bytes"] as? NSNumber)?.int64Value ?? 0
                photoDraft = record; detail = "\(paths.count) 张图片已临时下载，等待确认保存"; fraction = 1
            } catch { self.error = error.localizedDescription }
        } else if wasPreview, video?.isAlbum == true, code == 0, !cancelling, error == nil { error = "图片未完整下载，请重新解析。" }
        if wasPreview && photoDraft == nil { _ = cleanupPreview() }
        if var r = currentRecord {
            r.status = cancelling ? "已取消" : "失败"; r.error = cancelling ? nil : (error ?? "下载未完成，请重试。")
            records.insert(r, at: 0); save(); currentRecord = nil
        }
        if !cancelling && code != 0 && error == nil { error = "操作未完成，请重试。" }
        let cancelled = cancelling
        if cancelled { error = photoCleanupIssue; detail = "已取消，临时文件已清理"; video = nil; parsedText = ""; photoMessage = "临时图片已清理，已复制的图片仍可粘贴。" }
        busy = false; downloading = false; cancelling = false; process = nil; previewComplete = nil
        if wasPreview && downloadVideoAfterPreview && !cancelled && error == nil && video?.isAlbum == false { downloadVideoAfterPreview = false; start(isDownload: true) }
    }
}
