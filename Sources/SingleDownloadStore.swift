import Foundation
import AppKit
import Combine
import CryptoKit

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
    var statistics: WorkStatistics? = nil
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
    var isCover: Bool { mediaKind == "video_cover" }
    var isAlbum: Bool { mediaKind == "image_album" || isCover }
}
func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

@MainActor final class Store: ObservableObject {
    static var workerOverrideURL: URL?
    static var dataRootOverride: URL?
    @Published var text = ""
    @Published var quality: Quality = .original { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var folder: String { didSet { defaults.set(folder, forKey: "folder") } }
    @Published var choosingFolder = false
    @Published var captureVideo = true { didSet { if oldValue != captureVideo { captureOptionsChanged() } } }
    @Published var captureCover = false { didSet { if oldValue != captureCover { captureOptionsChanged() } } }
    var otherTaskIsBusy: () -> Bool = { false }
    var onStatistics: ((CreatorPost) -> Void)?
    @Published var viewingAlbum: Record?
    @Published var albumInitialIndex = 0
    @Published var photoDraft: Record?
    @Published var photoMessage: String?
    @Published private(set) var savingPhoto = false
    @Published var page = "新建下载" {
        didSet {
            if oldValue == "新建下载" && page != oldValue {
                if !linkItems.isEmpty { discardAllLinkItems() }
                else if previewJob != nil { cancelPhotoSave() }
            }
        }
    }
    @Published var linkItems: [SingleLinkItem] = []
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
    private var coverDigest: String?
    private var downloadVideoAfterPreview = false
    private var photoCleanupIssue: String?
    private var publishingTask: Task<PhotoPublication, Error>?
    private var saveTask: Task<Void, Never>?
    private var terminationCompletion: (() -> Void)?
    private let isLinkChild: Bool
    private var multiInputText = ""
    private var multiDuplicateCount = 0
    private var multiUnsupportedCount = 0
    private var multiTask: Task<Void, Never>?
    private var multiCancelRequested = false
    private var activeLinkID: UUID?
    private var multiDiscardRequested = false
    private var multiShutdownCompletion: (() -> Void)?

    init(isLinkChild: Bool = false) {
        self.isLinkChild = isLinkChild
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
        if !isLinkChild {
            do { try photoRepository.recoverAbandoned(confirmed: historyUnavailable ? nil : Set(completed.compactMap(\.path))) }
            catch { photoCleanupIssue = error.localizedDescription; self.error = "上次临时图文清理未完成：\(error.localizedDescription)" }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--prefill"), CommandLine.arguments.indices.contains(i + 1) { text = CommandLine.arguments[i + 1] }
    }
    var completed: [Record] { records.filter { $0.status == "完成" } }
    var filtered: [Record] { records.filter { (filter == "全部" || $0.status == filter) && (search.isEmpty || ($0.title + $0.author).localizedCaseInsensitiveContains(search)) } }
    var overall: Double {
        if multiTask != nil { return fraction }
        switch stage { case "download": return 0.08 + fraction * 0.55; case "export": return 0.63 + fraction * 0.32; case "verify": return 0.95 + fraction * 0.04; default: return 0.03 }
    }
    var photoPaths: [String] { photoDraft?.imagePaths ?? (result?.isAlbum == true ? result?.imagePaths : nil) ?? [] }
    var hasLiveChild: Bool { (process?.isRunning ?? false) || linkItems.contains { $0.child.hasLiveChild } }
    var isMultiLinkMode: Bool { !linkItems.isEmpty }
    var linkSummary: String {
        guard !linkItems.isEmpty else { return "" }
        let total = linkItems.count + multiDuplicateCount + multiUnsupportedCount
        var parts = ["\(total) 条链接 · \(linkItems.count) 个作品"]
        if multiDuplicateCount > 0 { parts.append("\(multiDuplicateCount) 条重复已合并") }
        if multiUnsupportedCount > 0 { parts.append("\(multiUnsupportedCount) 条不支持已跳过") }
        let saved = linkItems.filter(\.isCompleted).count
        if saved > 0 { parts.append("\(saved) 个已保存") }
        return parts.joined(separator: " · ")
    }
    var captureSelectionValid: Bool { captureVideo || captureCover }
    var confirmationTitle: String { photoDraft?.isCover == true && captureVideo && video?.isAlbum == false ? "确认保存并下载视频" : "确认保存" }
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
        for item in linkItems { item.applyCollectionRelocation(move) }
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
    func preview() {
        guard !busy, !otherTaskIsBusy(), captureSelectionValid else { return }
        if routeMultipleLinks(download: false) { return }
        startPreview(downloadVideo: false)
    }
    func download() {
        guard !busy, !otherTaskIsBusy(), captureSelectionValid else { return }
        if routeMultipleLinks(download: true) { return }
        if photoDraft != nil { confirmPhotoSave() }
        else if captureVideo, !captureCover, video?.isAlbum == false && parsedText == text { start(isDownload: true) }
        else { startPreview(downloadVideo: true) }
    }
    private func startPreview(downloadVideo: Bool) {
        guard !busy, !otherTaskIsBusy(), captureSelectionValid else { return }
        guard cleanupPreview() else { return }
        if let issue = photoCleanupIssue { error = issue; return }
        do { previewJob = try photoRepository.create() }
        catch { self.error = "临时图片目录创建失败：\(error.localizedDescription)"; return }
        downloadVideoAfterPreview = downloadVideo
        start(isDownload: false)
        if !busy { _ = cleanupPreview() }
    }
    func retry(_ r: Record) {
        guard !busy, !otherTaskIsBusy() else { return }
        captureVideo = !r.isCover; captureCover = r.isCover
        text = r.link; quality = r.quality; folder = r.folder; page = "新建下载"; video = nil; download()
    }
    private func captureOptionsChanged() {
        guard !busy else { return }
        if !linkItems.isEmpty { discardAllLinkItems() }
        viewingAlbum = nil
        guard cleanupPreview() else { return }
        video = nil; result = nil; parsedText = ""; photoMessage = nil; error = nil
        downloadVideoAfterPreview = false
    }
    @discardableResult func saveCoverRecords(_ values: [Record]) -> Bool {
        guard historyWritable, !historyUnavailable, !busy, values.allSatisfy({ $0.isCover && $0.status == "完成" && $0.imagePaths?.isEmpty == false }) else { return false }
        let previous = records
        records.insert(contentsOf: values, at: 0)
        guard save() else { records = previous; return false }
        return true
    }
    func cancel() {
        guard busy else { return }
        cancelling = true; detail = "正在取消并清理临时文件…"
        if multiTask != nil {
            multiCancelRequested = true
            for item in linkItems where !item.isCompleted { item.wasCancelled = true }
            if let item = linkItems.first(where: { $0.id == activeLinkID }) { item.child.cancel() }
            return
        }
        if savingPhoto { publishingTask?.cancel(); saveTask?.cancel() }
        else if let p = process, p.isRunning { p.terminate() }
    }
    @discardableResult private func cleanupPreview() -> Bool {
        guard let job = previewJob else { photoDraft = nil; coverDigest = nil; return true }
        do { try photoRepository.discard(job); previewJob = nil; photoDraft = nil; coverDigest = nil; return true }
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
        guard !busy, !otherTaskIsBusy(), let draft = photoDraft, let job = previewJob, let album = draft.path else { return }
        guard historyWritable else { error = "下载记录不可写，图片仍为临时预览。请先修复记录，或复制后取消保存。"; return }
        let startVideoAfterSave = draft.isCover && captureVideo && video?.isAlbum == false
        let sourceLink = draft.link, sourceID = draft.videoID
        busy = true; savingPhoto = true; cancelling = false; error = nil; photoMessage = nil; viewingAlbum = nil
        stage = "export"; fraction = 0; detail = draft.isCover ? "正在确认保存封面…" : "正在确认保存图片…"
        let repository = photoRepository, destination = folder, paths = draft.imagePaths ?? [], expectedDigest = coverDigest
        let operation = Task.detached(priority: .userInitiated) {
            if draft.isCover { try Self.validateCoverDigest(paths: paths, expected: expectedDigest) }
            let published = try repository.publish(job, album: album, paths: paths, destination: destination, cancelled: { Task.isCancelled })
            if draft.isCover { try Self.validateCoverDigest(paths: published.paths, expected: expectedDigest) }
            return published
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
                photoDraft = nil; coverDigest = nil; result = record; detail = draft.isCover ? "封面已保存" : "\(paths.count) 张图片已保存"; fraction = 1
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
            else if startVideoAfterSave, photoDraft == nil, result?.id == draft.id,
                    text == sourceLink, parsedText == sourceLink, video?.id == sourceID {
                downloadVideoAfterPreview = false
                start(isDownload: true)
            }
        }
    }
    nonisolated private static func validateCoverDigest(paths: [String], expected: String?) throws {
        guard paths.count == 1, let expected, expected.count == 64 else { throw PhotoDraftError(message: "封面校验信息不完整，请重新解析。") }
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: paths[0]), options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw PhotoDraftError(message: "临时封面已发生变化，未确认保存，请重新解析。") }
    }
    func shutdown(completion: (() -> Void)? = nil) {
        if !linkItems.isEmpty || multiTask != nil {
            if multiTask != nil {
                multiShutdownCompletion = completion
                multiDiscardRequested = true
                cancel()
            } else {
                clearLinkItems()
                completion?()
            }
            return
        }
        if savingPhoto { terminationCompletion = completion; cancel(); return }
        token = UUID()
        if let process, process.isRunning { process.terminate() }
        _ = cleanupPreview()
        completion?()
    }
    func discardPhotoPreviewForClosedWindow() {
        if !linkItems.isEmpty { discardAllLinkItems(); return }
        guard previewJob != nil else { return }
        cancelPhotoSave()
    }
    func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
    func reveal(_ r: Record) { if let path = r.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
    func play(_ r: Record, initialIndex: Int = 0) { if r.isAlbum { albumInitialIndex = initialIndex; viewingAlbum = r } else if let path = r.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
    func remove(_ r: Record) { let previous = records; records.removeAll { $0.id == r.id }; if !save() { records = previous } }
    func clearFailed() { let previous = records; records.removeAll { $0.status != "完成" }; if !save() { records = previous } }
    func inputChanged() {
        if !isLinkChild, !linkItems.isEmpty, multiInputText != text {
            discardAllLinkItems()
        }
        if !busy && parsedText != text {
            viewingAlbum = nil
            guard cleanupPreview() else { return }
            video = nil; result = nil; error = nil; photoMessage = nil
        }
    }
    /// URL extraction happens before any worker starts, so one paste is one ordered set.
    private func routeMultipleLinks(download: Bool) -> Bool {
        guard !isLinkChild else { return false }
        do {
            let parsed = try SingleLinkParser.parse(text)
            let count = parsed.links.count + parsed.duplicateCount + parsed.unsupportedCount
            guard count > 1 else {
                if !linkItems.isEmpty { clearLinkItems() }
                return false
            }
            guard !parsed.links.isEmpty else { error = "没有可提取的作品链接。"; return true }
            if multiInputText != text || linkItems.map(\.link) != parsed.links {
                clearLinkItems()
                guard cleanupPreview(), photoCleanupIssue == nil else { return true }
                multiInputText = text; multiDuplicateCount = parsed.duplicateCount; multiUnsupportedCount = parsed.unsupportedCount
                video = nil; result = nil; error = nil; photoMessage = nil; parsedText = ""
                linkItems = parsed.links.enumerated().map { index, link in
                    let child = Store(isLinkChild: true)
                    child.text = link; child.quality = quality; child.folder = folder
                    child.captureVideo = captureVideo; child.captureCover = captureCover; child.revealOnComplete = revealOnComplete
                    child.otherTaskIsBusy = { [weak self] in self?.otherTaskIsBusy() ?? true }
                    let item = SingleLinkItem(link: link, position: index + 1, child: child)
                    item.showRecord = { [weak self] record, initialIndex in self?.play(record, initialIndex: initialIndex) }
                    item.observation = child.objectWillChange.sink { [weak self, weak item] in
                        // @Published emits before mutation; mirror on the next main-queue turn.
                        DispatchQueue.main.async { [weak self, weak item] in
                            guard let self, let item else { return }
                            item.synchronize(); self.objectWillChange.send()
                            if self.activeLinkID == item.id {
                                self.stage = child.stage; self.received = child.received; self.total = child.total; self.speed = child.speed
                                self.detail = "第 \(item.position)/\(self.linkItems.count) 个 · \(child.detail)"
                            }
                        }
                    }
                    return item
                }
            }
            runLinkItems(linkItems, action: download ? .download : .preview)
        } catch { self.error = error.localizedDescription }
        return true
    }
    private enum LinkAction: Equatable { case preview, download, retry }
    func confirmLinkItem(_ id: UUID) {
        guard !busy, !otherTaskIsBusy(), captureSelectionValid,
              let item = linkItems.first(where: { $0.id == id }) else { return }
        if let draft = item.photoDraft, viewingAlbum?.id == draft.id { viewingAlbum = nil }
        runLinkItems([item], action: .download)
    }
    func retryLinkItem(_ id: UUID) {
        guard let item = linkItems.first(where: { $0.id == id }) else { return }
        runLinkItems([item], action: .retry)
    }
    func confirmAllLinkItems() { runLinkItems(linkItems.filter(\.canConfirm), action: .download) }
    func cancelLinkItem(_ id: UUID) {
        guard let item = linkItems.first(where: { $0.id == id }) else { return }
        let draftID = item.photoDraft?.id
        item.wasCancelled = true
        if item.child.busy { item.child.cancel() }
        else { item.child.cancelPhotoSave(); item.synchronize(); objectWillChange.send() }
        if draftID != nil && viewingAlbum?.id == draftID { viewingAlbum = nil }
    }
    func discardAllLinkItems() {
        viewingAlbum = nil
        if multiTask != nil {
            multiDiscardRequested = true; cancel()
        } else { clearLinkItems() }
    }
    private func clearLinkItems() {
        var issues: [String] = []
        for item in linkItems {
            item.observation = nil
            item.child.shutdown()
            if let issue = item.child.photoCleanupIssue { issues.append("第 \(item.position) 个：\(issue)") }
        }
        linkItems = []; multiInputText = ""; multiDuplicateCount = 0; multiUnsupportedCount = 0
        if !issues.isEmpty { photoCleanupIssue = issues.joined(separator: "；"); error = photoCleanupIssue }
    }
    private func synchronizeHistory(from child: Store) {
        records = child.records
        historyWritable = historyWritable && child.historyWritable
        historyUnavailable = historyUnavailable || child.historyUnavailable
        if let issue = child.historyIssue { historyIssue = issue }
    }
    private func runLinkItems(_ items: [SingleLinkItem], action: LinkAction) {
        guard !busy, !otherTaskIsBusy(), captureSelectionValid, !items.isEmpty else { return }
        if action != .preview && !historyWritable {
            error = "下载记录不可写，未开始保存。请先修复记录，待确认图片仍可复制。"; return
        }
        busy = true; downloading = action != .preview; cancelling = false; error = nil
        fraction = 0; stage = "parse"; detail = "准备处理 \(items.count) 个作品…"
        multiCancelRequested = false; multiDiscardRequested = false
        // Explicitly starting or retrying a new round re-enables previously cancelled rows.
        for item in items { item.wasCancelled = false }
        multiTask = Task { [self] in
            var processed = 0
            for item in items {
                if multiCancelRequested { break }
                if item.wasCancelled { processed += 1; continue }
                if item.isCompleted { processed += 1; continue }
                if action == .preview && item.child.video != nil && item.error == nil && !item.wasCancelled { processed += 1; continue }
                let child = item.child
                child.onStatistics = onStatistics
                child.records = records; child.historyWritable = historyWritable; child.historyUnavailable = historyUnavailable; child.historyIssue = historyIssue
                child.quality = quality; child.folder = folder; child.revealOnComplete = revealOnComplete
                if action != .preview && !historyWritable {
                    child.error = "下载记录不可写，本条未开始保存。"; item.synchronize(); processed += 1; continue
                }
                activeLinkID = item.id; item.wasCancelled = false
                if action == .retry && child.photoDraft != nil && child.error != nil { child.cancelPhotoSave() }
                if action == .preview { child.preview() }
                else if item.completedResults.contains(where: \.isCover), captureVideo, item.video?.isAlbum == false {
                    // A confirmed cover remains saved if its later video fails; retry only that video.
                    child.video = item.video
                    child.start(isDownload: true)
                } else { child.download() }
                item.synchronize()
                while child.busy {
                    fraction = (Double(processed) + child.overall) / Double(items.count)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                synchronizeHistory(from: child); item.synchronize()
                processed += 1; fraction = Double(processed) / Double(items.count)
                objectWillChange.send()
            }
            activeLinkID = nil
            let cancelled = multiCancelRequested
            if cancelled {
                for item in linkItems where !item.isCompleted {
                    item.wasCancelled = true; item.child.cancelPhotoSave(); item.synchronize()
                    if let issue = item.child.photoCleanupIssue { photoCleanupIssue = issue; error = issue }
                }
            }
            let failed = linkItems.filter { $0.error != nil }.count
            let awaiting = linkItems.filter { $0.photoDraft != nil }.count
            let saved = linkItems.filter(\.isCompleted).count
            detail = cancelled ? "本次处理已取消，已保存的作品保留。" : "处理结束 · \(saved) 个已保存 · \(awaiting) 个待确认 · \(failed) 个失败"
            busy = false; downloading = false; cancelling = false; multiTask = nil
            if multiDiscardRequested { clearLinkItems(); multiDiscardRequested = false }
            if let completion = multiShutdownCompletion { multiShutdownCompletion = nil; completion() }
            objectWillChange.send()
        }
    }
    private func start(isDownload: Bool) {
        guard !busy, !otherTaskIsBusy(), captureSelectionValid, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isDownload && !captureVideo { return }
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
        else if let previewJob { p.arguments! += [captureCover ? "--preview-cover" : "--preview-images", "--folder", previewJob.directory.path] }
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
                if (info.isAlbum || captureCover) && purpose == .preview {
                    downloading = true; detail = captureCover ? "正在临时下载封面…" : "图文已识别，正在临时下载图片…"
                }
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
                records.insert(r, at: 0)
                let didSave = save()
                if didSave, let value = video?.statistics, value.valid, let id = r.videoID,
                   MediaPlatform.detect(link: r.link) == .wechat {
                    var post = CreatorPost(id: id, link: r.link, title: r.title, author: r.author, isVideo: true)
                    post.statistics = value
                    onStatistics?(post)
                }
                if isLinkChild && !didSave {
                    records.removeAll { $0.id == r.id }; result = nil
                    error = "视频文件已生成，但下载记录写入失败，文件保留在：\(r.path ?? folder)。\(historyIssue ?? "")"
                    detail = "记录写入失败，已生成文件保留"
                } else {
                    result = r; detail = "视频已保存"; fraction = 1
                    if revealOnComplete { reveal(r) }
                }
                currentRecord = nil
            }
        case "error": error = event["message"] as? String ?? "下载失败，请重试。"
        case "cancelled": cancelling = true
        default: break
        }
    }
    private func finish(job: UUID, code: Int32) {
        guard token == job else { return }
        let wasPreview = purpose == .preview
        if wasPreview, !cancelling, code == 0, error == nil, let info = video,
            let event = previewComplete, let kind = event["mediaKind"] as? String,
            ((kind == "image_album" && info.isAlbum && !captureCover) || (kind == "video_cover" && captureCover)), let previewJob,
            let path = event["path"] as? String, let paths = event["imagePaths"] as? [String] {
            do {
                try photoRepository.validate(previewJob, album: path, paths: paths)
                if kind == "video_cover" {
                    guard paths.count == 1, let digest = event["imageSHA256"] as? String,
                          digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                        throw PhotoDraftError(message: "封面校验信息不完整，请重新解析。")
                    }
                    coverDigest = digest
                }
                var record = Record(title: info.title, author: info.author, link: parsedText, quality: quality, folder: folder, status: "待确认保存")
                record.path = path; record.imagePaths = paths; record.mediaKind = kind; record.videoID = info.id
                record.description = info.description; record.width = event["width"] as? Int ?? info.width; record.height = event["height"] as? Int ?? info.height
                record.bytes = (event["bytes"] as? NSNumber)?.int64Value ?? 0
                photoDraft = record; detail = kind == "video_cover" ? "封面已临时下载，等待确认保存" : "\(paths.count) 张图片已临时下载，等待确认保存"; fraction = 1
            } catch { self.error = error.localizedDescription }
        } else if wasPreview, video?.isAlbum == true || captureCover, code == 0, !cancelling, error == nil {
            error = captureCover ? "封面未完整下载，请重新解析。" : "图片未完整下载，请重新解析。"
        }
        if wasPreview && photoDraft == nil { _ = cleanupPreview() }
        if var r = currentRecord {
            r.status = cancelling ? "已取消" : "失败"; r.error = cancelling ? nil : (error ?? "下载未完成，请重试。")
            records.insert(r, at: 0); save(); currentRecord = nil
        }
        if !cancelling && code != 0 && error == nil { error = "操作未完成，请重试。" }
        let cancelled = cancelling
        if cancelled { error = photoCleanupIssue; detail = "已取消，临时文件已清理"; video = nil; parsedText = ""; photoMessage = "临时图片已清理，已复制的图片仍可粘贴。" }
        busy = false; downloading = false; cancelling = false; process = nil; previewComplete = nil
        if wasPreview && downloadVideoAfterPreview && captureVideo && !captureCover && !cancelled && error == nil && video?.isAlbum == false { downloadVideoAfterPreview = false; start(isDownload: true) }
    }
}
