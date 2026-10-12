import Foundation
import AppKit
import Combine
import CryptoKit

/// Pure metadata rules shared by the save event and the foreground public-count check.
enum ArticleMetadataRules {
    static let monitoringLimit = 200
    static let monitoringLimitMessage = "前台一次最多检查200篇的公开互动数据，未开始检查。"

    static func excerpt(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let scalars = raw.unicodeScalars.filter { scalar in
            scalar.value >= 32 || scalar == "\n" || scalar == "\t"
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(2000))
    }
    static func coverURL(_ value: Any?) -> String? {
        ArticleCardContent.approvedCover(value as? String)?.absoluteString
    }
    /// A downloaded cover may be recorded only when the file is inside that article directory.
    static func coverPath(_ value: Any?, articleDirectory: String) -> String? {
        guard let raw = value as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\0"), !text.contains("\n"), !text.contains("\r") else { return nil }
        let articleRoot = URL(fileURLWithPath: articleDirectory).resolvingSymlinksInPath()
        let candidate: URL
        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL { candidate = url }
        else if text.hasPrefix("/") { candidate = URL(fileURLWithPath: text) }
        else { candidate = articleRoot.appendingPathComponent(text) }
        let file = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = articleRoot.path + "/"
        guard file.path.hasPrefix(prefix) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return file.path
    }
    static func applyingPublicationMetadata(to record: ArticleRecord, event: [String: Any], snapshot: [String: Any]?, articleDirectory: String, action: String) -> ArticleRecord {
        var copy = record
        if let excerpt = excerpt(event["excerpt"]) ?? excerpt(snapshot?["excerpt"]) { copy.excerpt = excerpt }
        if let cover = coverURL(event["coverURL"]) ?? coverURL(snapshot?["coverURL"]) { copy.coverURL = cover }
        if action == "download", let path = coverPath(event["coverPath"], articleDirectory: articleDirectory) { copy.coverPath = path }
        if let snapshot, let statistics = successStatistics(snapshot, previous: copy.statistics, checkedAt: Date()) { copy.statistics = statistics }
        return copy
    }
    static func failureStatistics(_ previous: ArticleStatistics?, message: String, checkedAt: Date) -> ArticleStatistics {
        var stats = previous ?? ArticleStatistics()
        stats.error = String(message.prefix(500))
        stats.checkedAt = checkedAt
        stats.historical = [("read", stats.read), ("like", stats.like), ("watching", stats.watching), ("comments", stats.comments)].compactMap { $0.1 == nil ? nil : $0.0 }
        return stats
    }
    /// Nil means the page did not return a statistics object, so the caller must keep the previous counters.
    static func successStatistics(_ payload: [String: Any], previous: ArticleStatistics? = nil, checkedAt: Date) -> ArticleStatistics? {
        guard let metrics = payload["statistics"] as? [String: Any] else { return nil }
        var stats = ArticleStatistics.snapshot(["statistics": metrics])
        stats.checkedAt = checkedAt
        var historical: [String] = []
        if stats.read == nil, let value = previous?.read { stats.read = value; historical.append("read") }
        if stats.like == nil, let value = previous?.like { stats.like = value; historical.append("like") }
        if stats.watching == nil, let value = previous?.watching { stats.watching = value; historical.append("watching") }
        if stats.comments == nil, let value = previous?.comments { stats.comments = value; historical.append("comments") }
        stats.historical = historical.isEmpty ? nil : historical
        stats.error = historical.isEmpty ? nil : historical.map { ["read": "阅读", "like": "点赞", "watching": "在看", "comments": "评论"][$0] ?? $0 }.joined(separator: "、") + "本次未公开，* 为上次公开值。"
        return stats
    }
}

@MainActor final class ArticleStore: ObservableObject {
    static var dataRootOverride: URL?
    static var workerOverrideURL: URL?
    static let metadataCheckInterval: TimeInterval = 60
    @Published var text = ""
    @Published var records: [ArticleRecord] = []
    @Published private(set) var busy = false { didSet { if busy && !oldValue { pauseMetadataLoad() } } }
    @Published var detail = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var choosingFolder = false
    @Published var preview: ArticlePreview? { didSet { if preview != nil && oldValue == nil { pauseMetadataLoad() } } }
    @Published var browserVisible = false { didSet { if browserVisible && !oldValue { pauseMetadataLoad() } } }
    @Published var browserRecord: UUID?
    @Published private(set) var refreshingMetadata = false
    @Published var folder: String { didSet { defaults.set(folder, forKey: "articleFolder") } }
    let loader: ArticlePageLoader
    let metadataLoader: ArticleMetadataLoader
    let coverCacheRoot: URL
    /// Changes on start, stop, and shutdown. In-flight page callbacks must match it or they are dropped.
    var monitoringGeneration: UUID { metadataGeneration }
    private let repository: HistoryRepository<ArticleRecord>
    private let defaults: UserDefaults
    static func testPreferencesSuite(root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "com.local.shiying.articles.testing." + digest
    }
    private var blocked = false
    private var process: Process?
    private var generation = UUID()
    private var queue: [UUID] = []
    private var current: UUID?
    private var currentAction = "download"
    private var returned = false
    private var cancelling = false
    private var snapshots: [UUID: [String: Any]] = [:]
    private var snapshotOrder: [UUID] = []
    private let previewRoot: URL
    private var currentOutput: URL?
    private var metadataGeneration = UUID()
    private var metadataTask: Task<Void, Never>?
    private var monitoredIDs: [UUID] = []
    private var metadataRefreshRequested = false
    private var activationObserver: AnyCancellable?
    private var metadataPaused: Bool { busy || browserVisible || preview != nil || !NSApplication.shared.isActive }
    init() {
        let testing = Self.dataRootOverride != nil || CommandLine.arguments.contains("--test-mode")
        let root = Self.dataRootOverride ?? shiyingTestDataRoot(fallback: "/tmp/shiying-articles-test")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/拾影")
        repository = HistoryRepository(fileURL: root.appendingPathComponent("articles/article-library.json"))
        defaults = testing ? UserDefaults(suiteName: Self.testPreferencesSuite(root: root))! : .standard
        loader = ArticlePageLoader(testing: testing)
        metadataLoader = ArticleMetadataLoader(testing: testing)
        let d = defaults
        let initial = testing ? root.appendingPathComponent("article-files") : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/拾影资料")
        folder = d.string(forKey: "articleFolder") ?? (FileManager.default.fileExists(atPath: initial.path) ? initial.path : testing ? initial.path : FileManager.default.homeDirectoryForCurrentUser.path + "/Downloads")
        previewRoot = FileManager.default.temporaryDirectory.appendingPathComponent((Bundle.main.bundleIdentifier ?? "com.local.shiying") + ".article-previews").appendingPathComponent(UUID().uuidString)
        // App cache only. ArticleCoverView may create it later; opening the list must not write it.
        coverCacheRoot = root.appendingPathComponent("articles/cover-cache")
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.pauseMetadataLoad() }
        do {
            records = try repository.load()
            guard records.count <= 50_000, Set(records.map(\.id)).count == records.count,
                  records.allSatisfy({ (try? ArticleInput.canonical($0.link)) == $0.link && $0.imageCount >= 0 && $0.characters >= 0 && $0.bytes >= 0 }) else {
                throw WorkStatisticsError(message: "公众号记录包含无效字段，原文件保留。")
            }
            for i in records.indices where records[i].status == .reading || records[i].status == .saving { records[i].status = .pending }
        } catch { blocked = true; self.error = "公众号记录读取失败，暂停写入，原文件保留：" + error.localizedDescription }
    }
    @discardableResult private func persist(_ next: [ArticleRecord]) -> Bool {
        guard !blocked else { return false }
        do { try repository.save(next); records = next; return true }
        catch { blocked = true; self.error = "公众号记录保存失败，原记录保留：" + error.localizedDescription; return false }
    }
    func addLinks() {
        guard !busy, !blocked else { return }
        do {
            let links = try ArticleInput.links(text)
            var next = records, added = 0
            for link in links where !next.contains(where: { $0.link == link }) { next.append(ArticleRecord(link: link)); added += 1 }
            guard next.count <= 50_000 else { throw WorkStatisticsError(message: "公众号资料库超过50000篇，未添加新链接。") }
            if persist(next) { error = nil; notice = added == 0 ? "这些文章已在列表中，可预览或重新保存。" : "已添加\(added)篇文章。点击「保存全部」保存正文和图片。" }
        } catch { self.error = error.localizedDescription }
    }
    func paste() { if let value = NSPasteboard.general.string(forType: .string), !busy { text = value } }
    func saveAll() {
        guard !busy, !blocked else { return }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addLinks(); if error != nil { return } }
        let ids = records.filter { $0.status != .saved || !$0.available }.map(\.id)
        guard !ids.isEmpty else { notice = "列表中的文章已经保存。"; return }
        guard ids.count <= 200 else { error = "有\(ids.count)篇待保存文章，超过单次200篇；请逐篇保存或移除不需要的待保存记录后再批量保存。"; return }
        do { _ = try FolderBrowser.directory(folder, writable: true) } catch { self.error = error.localizedDescription; choosingFolder = true; return }
        queue = ids; generation = UUID(); cancelling = false; busy = true; self.error = nil; notice = nil; advance()
    }
    func save(_ record: ArticleRecord) { begin(record, action: "download") }
    func showPreview(_ record: ArticleRecord) {
        if record.available, let path = record.path { preview = ArticlePreview(title: record.title, path: path, recordID: record.id); return }
        begin(record, action: "preview")
    }
    private func begin(_ record: ArticleRecord, action: String) {
        guard !busy, !blocked else { return }
        if action == "download" { do { _ = try FolderBrowser.directory(folder, writable: true) } catch { self.error = error.localizedDescription; choosingFolder = true; return } }
        queue = [record.id]; currentAction = action; generation = UUID(); cancelling = false; busy = true; error = nil; notice = nil; advance(action: action)
    }
    private func advance(action: String = "download") {
        if cancelling { finishCancellation(); return }
        guard busy, !blocked else { busy = false; return }
        guard !queue.isEmpty else {
            current = nil; busy = false; detail = ""
            notice = action == "preview" ? "正文预览已就绪，确认后可保存正文和图片。" : "文章列表：\(records.filter { $0.status == .saved }.count)篇已保存，\(records.filter { $0.status == .failed }.count)篇失败。"
            return
        }
        let id = queue.removeFirst(); current = id; currentAction = action; returned = false
        guard let i = records.firstIndex(where: { $0.id == id }) else { advance(action: action); return }
        records[i].status = .reading; records[i].error = nil; detail = "正在内置网页读取文章正文…"
        let record = records[i], run = generation
        if let snapshot = snapshots[id] { startWorker(record, snapshot: snapshot, token: run); return }
        loader.load(record.link) { [weak self] result in
            guard let self, self.generation == run, self.busy, self.current == id else { return }
            switch result {
            case .success(let snapshot): self.remember(snapshot, id: id); self.startWorker(record, snapshot: snapshot, token: run)
            case .failure(let issue): self.fail(id, issue.localizedDescription); self.advance(action: action)
            }
        }
    }
    private func remember(_ snapshot: [String: Any], id: UUID) {
        snapshots[id] = snapshot; snapshotOrder.removeAll { $0 == id }; snapshotOrder.append(id)
        while snapshotOrder.count > 10 { snapshots.removeValue(forKey: snapshotOrder.removeFirst()) }
    }
    private func fail(_ id: UUID, _ message: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        var next = records; next[i].status = .failed; next[i].error = message
        _ = persist(next)
    }
    private func startWorker(_ record: ArticleRecord, snapshot: [String: Any], token: UUID) {
        guard let executable = Self.workerOverrideURL ?? Bundle.main.resourceURL?.appendingPathComponent("worker/拾影Worker"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            fail(record.id, "公众号采集组件缺失，请重新安装完整App。"); advance(action: currentAction); return
        }
        let outputRoot: URL
        do {
            if currentAction == "preview" {
                outputRoot = previewRoot.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            } else { outputRoot = try FolderBrowser.directory(folder, writable: true) }
        } catch { fail(record.id,error.localizedDescription); advance(action: currentAction); return }
        currentOutput = outputRoot
        guard let input = try? JSONSerialization.data(withJSONObject: ["links":[record.link], "snapshots":[record.link:snapshot]]), input.count <= 3_145_728 else {
            fail(record.id,"文章正文超过3 MiB或无法编码，未保存。"); advance(action: currentAction); return
        }
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i].status = .saving }
        let child = Process(), output = Pipe(), stdin = Pipe(), action = currentAction
        child.executableURL = executable; child.arguments = ["articles", "--article-action", action, "--folder", outputRoot.path]
        child.standardInput = stdin; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        do { try child.run(); process = child } catch { fail(record.id,"公众号组件启动失败：" + error.localizedDescription); advance(action: action); return }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() } catch { child.terminate() }
            var buffer = Data()
            while true {
                let bytes = output.fileHandleForReading.availableData
                if bytes.isEmpty { break }; buffer.append(bytes)
                if buffer.count > 262_144 { child.terminate(); break }
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { [weak self] in guard let self, self.generation == token, self.current == record.id else { return }; self.consume(event, record: record, action: action, outputRoot: outputRoot) }
                    }
                }
            }
            child.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.current == record.id else { return }
                self.process = nil
                if self.cancelling { self.finishCancellation(); return }
                if !self.returned { self.fail(record.id,"公众号组件未完整返回（退出码\(child.terminationStatus)）；原文件和已有记录保留。") }
                self.advance(action: action)
            }
        }
    }
    private func consume(_ event: [String: Any], record: ArticleRecord, action: String, outputRoot: URL) {
        guard let name = event["event"] as? String else { return }
        if name == "article_progress", event["link"] as? String == record.link { detail = event["detail"] as? String ?? detail; return }
        if name == "article_failure", event["link"] as? String == record.link { returned = true; fail(record.id,event["message"] as? String ?? "文章采集失败，请在内置网页检查。"); return }
        guard name == (action == "preview" ? "article_preview" : "article_saved"), event["link"] as? String == record.link,
              let data = event["article"] as? [String: Any], let path = data["path"] as? String,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(outputRoot.resolvingSymlinksInPath().path + "/"),
              let title = data["title"] as? String, !title.isEmpty, title.count <= 1000,
              let count = data["imageCount"] as? Int, count >= 0, count <= 500,
              let characters = data["characters"] as? Int, characters >= 0,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("文章.html").path),
              let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        returned = true
        var next = records; next[index].title = title; next[index].account = data["account"] as? String ?? "公众号"
        next[index].author = data["author"] as? String ?? ""; next[index].published = data["published"] as? String ?? ""
        next[index].imageCount = count; next[index].characters = characters; next[index].error = nil
        next[index] = ArticleMetadataRules.applyingPublicationMetadata(to: next[index], event: data, snapshot: snapshots[record.id], articleDirectory: path, action: action)
        if action == "preview" {
            next[index].status = record.status == .saved ? .saved : .pending
            records = next; preview = ArticlePreview(title: title,path: path,recordID: record.id)
        } else {
            next[index].status = .saved; next[index].path = path; next[index].date = Date(); next[index].bytes = (data["bytes"] as? NSNumber)?.int64Value ?? 0
            if !persist(next) { error = (error ?? "") + " 已完成文件保留在：" + path }
            snapshots.removeValue(forKey: record.id); snapshotOrder.removeAll { $0 == record.id }
        }
    }
    func openBrowser(_ record: ArticleRecord) {
        guard !busy else { return }
        browserRecord = record.id; browserVisible = true
        loader.load(record.link) { _ in }
    }
    func readBrowser() {
        guard !busy, let id = browserRecord, records.contains(where: { $0.id == id }) else { return }
        detail = "正在读取当前网页正文…"
        loader.captureCurrent { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.remember(snapshot,id: id); self.browserVisible = false
                if let record = self.records.first(where: { $0.id == id }) { self.showPreview(record) }
            case .failure(let issue): self.error = issue.localizedDescription
            }
        }
    }
    func reveal(_ record: ArticleRecord) { if let path = record.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
    func discardPreview(_ path: String) {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if url.path.hasPrefix(previewRoot.resolvingSymlinksInPath().path + "/") { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
    func remove(_ record: ArticleRecord) {
        guard !busy else { return }
        let removed = persist(records.filter { $0.id != record.id })
        if removed { monitoredIDs.removeAll { $0 == record.id } }
        snapshots.removeValue(forKey: record.id)
    }
    func cancel() {
        guard busy, !cancelling else { return }
        cancelling = true; queue = []; loader.cancel()
        if let process {
            detail = "正在停止采集并清理临时文件…"
            if process.isRunning { process.terminate() }
            return
        }
        finishCancellation()
    }
    private func finishCancellation() {
        if let current, let i = records.firstIndex(where: { $0.id == current }), records[i].status != .saved { var next = records; next[i].status = .pending; next[i].error = nil; _ = persist(next) }
        generation = UUID(); current = nil; busy = false; cancelling = false; detail = ""; notice = "采集已停止，已保存的文章保留。"
    }
    func shutdown() {
        stopMonitoring(); cancel(); loader.cancel(); snapshots = [:]; try? FileManager.default.removeItem(at: previewRoot)
    }

    /// One pass for missing covers/excerpts. Interaction data reading has been cancelled by the user.
    func prepareCards(ids: [UUID]) {
        stopMonitoring()
        guard !blocked else { return }
        let ids = Array(ids.prefix(200)).filter { id in
            guard let record = records.first(where: { $0.id == id }) else { return false }
            return record.excerpt == nil || (record.coverURL == nil && ArticleCardContent.localCover(record) == nil)
        }
        guard !ids.isEmpty else { return }
        let session = metadataGeneration
        metadataTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.metadataGeneration == session { self.metadataTask = nil } }
            var index = 0
            while index < ids.count, self.metadataGeneration == session, !Task.isCancelled, !self.blocked {
                while self.metadataPaused && self.metadataGeneration == session && !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                }
                guard self.metadataGeneration == session, !Task.isCancelled,
                      let record = self.records.first(where: { $0.id == ids[index] }) else { return }
                let result = await self.metadataLoader.fetchPresentation(record.link)
                guard self.metadataGeneration == session, !Task.isCancelled else { return }
                if self.metadataPaused { continue }
                if case .success(let payload) = result,
                   let position = self.records.firstIndex(where: { $0.id == record.id }) {
                    var next = self.records
                    if let cover = ArticleMetadataRules.coverURL(payload["coverURL"]) { next[position].coverURL = cover }
                    if let excerpt = ArticleMetadataRules.excerpt(payload["excerpt"]) { next[position].excerpt = excerpt }
                    // Keep saved files, save status and previously stored statistics untouched.
                    if next[position].coverURL != self.records[position].coverURL || next[position].excerpt != self.records[position].excerpt {
                        guard self.persist(next) else { return }
                    }
                }
                index += 1
            }
        }
    }

    /// Foreground article page: pass the explicit visible record IDs, at most 200, and call stopMonitoring on disappear.
    func startMonitoring(ids: [UUID]) {
        guard !blocked else { return }
        var unique: [UUID] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        guard unique.count <= ArticleMetadataRules.monitoringLimit else {
            error = ArticleMetadataRules.monitoringLimitMessage; return
        }
        if error == ArticleMetadataRules.monitoringLimitMessage { error = nil }
        let known = unique.filter { id in records.contains(where: { $0.id == id }) }
        guard !known.isEmpty else { stopMonitoring(); return }
        replaceMonitoringSession(ids: known)
    }
    func stopMonitoring() {
        metadataGeneration = UUID()
        monitoredIDs = []
        metadataRefreshRequested = false
        metadataTask?.cancel(); metadataTask = nil
        metadataLoader.cancel()
        refreshingMetadata = false
    }
    /// Asks the running foreground session to start another serial pass without waiting out the minute.
    func refreshMetadata() {
        guard !blocked, metadataTask != nil, !monitoredIDs.isEmpty else { return }
        metadataRefreshRequested = true
    }
    private func replaceMonitoringSession(ids: [UUID]) {
        let session = UUID()
        metadataGeneration = session
        monitoredIDs = ids
        metadataRefreshRequested = false
        metadataLoader.cancel()
        metadataTask?.cancel()
        refreshingMetadata = false
        metadataTask = Task { [weak self] in await self?.monitorLoop(session) }
    }
    private func pauseMetadataLoad() { metadataLoader.cancel() }
    private func monitorLoop(_ session: UUID) async {
        defer { if metadataGeneration == session { refreshingMetadata = false } }
        while metadataGeneration == session, !Task.isCancelled {
            let started = Date()
            await runSerialPass(session)
            if metadataGeneration != session || Task.isCancelled { break }
            if metadataRefreshRequested { metadataRefreshRequested = false; continue }
            let remaining = Self.metadataCheckInterval - Date().timeIntervalSince(started)
            if remaining > 0 {
                let woke = await waitRemaining(remaining, session: session)
                if !woke { break }
            }
            if metadataRefreshRequested { metadataRefreshRequested = false }
        }
    }
    private func waitRemaining(_ remaining: TimeInterval, session: UUID) async -> Bool {
        var left = remaining
        while left > 0 {
            if metadataGeneration != session || Task.isCancelled { return false }
            if metadataRefreshRequested { return true }
            let step = min(0.25, left)
            do { try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000)) }
            catch { return false }
            left -= step
        }
        return metadataGeneration == session && !Task.isCancelled
    }
    private enum MetadataStep { case advance, retry, stop }
    private func runSerialPass(_ session: UUID) async {
        let ids = monitoredIDs
        var index = 0
        while index < ids.count {
            if metadataGeneration != session || Task.isCancelled { return }
            while metadataPaused && metadataGeneration == session && !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
            if metadataGeneration != session || Task.isCancelled { return }
            switch await checkOne(ids[index], session: session) {
            case .retry: continue
            case .stop: return
            case .advance: index += 1
            }
        }
    }
    private func checkOne(_ id: UUID, session: UUID) async -> MetadataStep {
        guard metadataGeneration == session else { return .stop }
        guard !blocked else { return .stop }
        guard !metadataPaused else { return .retry }
        guard let link = records.first(where: { $0.id == id })?.link else { return .advance }
        refreshingMetadata = true
        let result = await metadataLoader.fetch(link)
        if metadataGeneration == session { refreshingMetadata = false }
        guard metadataGeneration == session else { return .stop }
        if case .failure(is ArticleMetadataCancelled) = result { return metadataPaused ? .retry : .advance }
        guard !metadataPaused else { return .retry }
        let checkedAt = Date()
        let committed: Bool
        switch result {
        case .success(let payload): committed = commitMetadata(id: id, payload: payload, failure: nil, checkedAt: checkedAt, session: session)
        case .failure(let issue): committed = commitMetadata(id: id, payload: nil, failure: issue.localizedDescription, checkedAt: checkedAt, session: session)
        }
        if metadataGeneration != session { return .stop }
        if !committed && blocked { return .stop }
        return .advance
    }
    /// Updates excerpt, cover URL, and statistics only. Saved status, article path, cover file, and user files stay as they were.
    @discardableResult func commitMetadata(id: UUID, payload: [String: Any]?, failure: String?, checkedAt: Date, session: UUID? = nil) -> Bool {
        if let session, metadataGeneration != session { return false }
        guard !blocked, let index = records.firstIndex(where: { $0.id == id }) else { return false }
        var next = records
        let original = next[index]
        if let failure {
            next[index].statistics = ArticleMetadataRules.failureStatistics(original.statistics, message: failure, checkedAt: checkedAt)
        } else if let payload, let stats = ArticleMetadataRules.successStatistics(payload, previous: original.statistics, checkedAt: checkedAt) {
            if let excerpt = ArticleMetadataRules.excerpt(payload["excerpt"]) { next[index].excerpt = excerpt }
            if let cover = ArticleMetadataRules.coverURL(payload["coverURL"]) { next[index].coverURL = cover }
            next[index].statistics = stats
        } else {
            next[index].statistics = ArticleMetadataRules.failureStatistics(original.statistics, message: "网页没有返回公开互动数据，原有数值保留。", checkedAt: checkedAt)
        }
        next[index].status = original.status
        next[index].path = original.path
        next[index].coverPath = original.coverPath
        next[index].link = original.link
        next[index].title = original.title
        next[index].account = original.account
        next[index].author = original.author
        next[index].published = original.published
        next[index].imageCount = original.imageCount
        next[index].characters = original.characters
        next[index].bytes = original.bytes
        next[index].error = original.error
        next[index].date = original.date
        next[index].id = original.id
        if original.status == .pending, let payload {
            if let title = ArticleMetadataRules.excerpt(payload["title"]), !title.isEmpty { next[index].title = String(title.prefix(1000)) }
            if let account = ArticleMetadataRules.excerpt(payload["account"]) { next[index].account = String(account.prefix(200)) }
            if let author = ArticleMetadataRules.excerpt(payload["author"]) { next[index].author = String(author.prefix(200)) }
            if let published = ArticleMetadataRules.excerpt(payload["published"]) { next[index].published = String(published.prefix(100)) }
        }
        return persist(next)
    }
}
