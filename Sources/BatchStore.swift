import Foundation
import AppKit
import Combine
import Darwin

// MARK: - 批量收集队列（任务 B）
//
// 依赖 A 的 BatchCore.swift（BatchStatus / StudyCollection / BatchItem / BatchLibraryState /
// BatchImportPreview / BatchLinkParser / BatchRepository）与 App.swift 的 Quality。
// 本页管理队列与文件夹；真实移动事务同步 history.json 的路径，不自动联网。

@MainActor
final class BatchStore: ObservableObject {
    @Published var inputText = ""
    @Published var quality: Quality = .original
    @Published var includeAudio = true
    @Published var collections: [StudyCollection] = []
    @Published var items: [BatchItem] = []
    @Published var imports: [BatchImportSource] = []
    @Published var selectedCollectionID: UUID?
    @Published var search = ""
    @Published var statusFilter = "全部"
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var detail = ""
    @Published var progress: Double = 0
    @Published var error: String?
    @Published var notice: String?
    @Published var newCollectionName = ""
    @Published var parentFolder: String
    @Published var choosingParentFolder = false
    @Published var viewingAlbum: BatchItem?
    @Published var notesDraft = ""
    @Published private(set) var lastCollectionMove: CollectionRelocation?

    /// 仅测试宿主注入 worker 路径；正式包从不设置，走 Bundle 内的拾影Worker。
    static var workerOverrideURL: URL?

    /// 仅测试宿主注入 ffmpeg/ffprobe 所在目录；正式包走 Bundle Resources/Tools。
    static var toolsDirectoryOverride: URL?

    /// 仅测试宿主注入数据根（其下建 batch/batch-library.json 与 资料/）；正式包从不设置。
    /// 并发会话若共用固定 /tmp 根会互相污染，所以每个测试宿主各用自己的目录。
    static var dataRootOverride: URL?
    var otherTaskIsBusy: () -> Bool = { false }
    var onStatistics: ((CreatorPost) -> Void)?

    private let repository: BatchRepository
    private var libraryUnwritable = false
    private var process: Process?
    private var entryID: UUID?
    private var generation = UUID()
    private var cancelRequested = false
    private var reuseDonor: BatchItem?
    private var lastComplete: [String: Any]?
    private var lastItemError: String?
    private var lastStatistics: WorkStatistics?
    private var runTotal = 0
    private var runDone = 0
    private enum Phase { case video, audio }
    private var phase: Phase = .video
    private var stagingAudio: URL?
    private var audioOnlyQueue: [UUID] = []
    private var runScope: Set<UUID>?

    init() {
        let testing = CommandLine.arguments.contains("--test-mode")
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 数据根优先级：测试宿主注入 > --test-mode 独立临时根 > 正式 Application Support。
        let injected = BatchStore.dataRootOverride
        let support = injected
            ?? shiyingTestDataRoot(fallback: "/tmp/shiying-batch-test-data")
            ?? home.appendingPathComponent("Library/Application Support/拾影")
        repository = BatchRepository(rootURL: support.appendingPathComponent("batch"))
        let parent = (injected != nil || testing)
            ? support.appendingPathComponent("资料")
            : home.appendingPathComponent("Downloads/拾影资料")
        parentFolder = parent.path
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            let state = try repository.load()
            collections = state.collections
            imports = state.imports
            items = []
            var resumed = 0
            for item in state.items {
                var restored = item
                if restored.status == .running {
                    restored.status = .pending
                    restored.error = nil
                    resumed += 1
                }
                items.append(restored)
            }
            if resumed > 0 {
                notice = "上次有 \(resumed) 条任务在下载中退出，已恢复为待处理；点「开始队列」才会继续，不会自动联网。"
            }
            selectedCollectionID = collections.first?.id
            notesDraft = selectedCollection?.notes ?? ""
            if resumed > 0 { persist() }
        } catch {
            libraryUnwritable = true
            self.error = "批量资料库读取失败：\(error.localizedDescription)。为不覆盖现有数据，本次会话禁止写入资料库，请备份后修复 batch-library.json。"
        }
    }

    var canWriteLibrary: Bool { !libraryUnwritable }

    // MARK: - 只读派生

    var selectedCollection: StudyCollection? {
        collections.first { $0.id == selectedCollectionID }
    }

    var selectedItems: [BatchItem] {
        items.filter { item in
            (selectedCollectionID == nil || item.collectionID == selectedCollectionID)
                && matchesFilter(item) && matchesSearch(item)
        }
    }

    var preview: BatchImportPreview? {
        try? BatchLinkParser.preview(inputText, existing: Set(existingLinks))
    }

    var pendingCount: Int { items.filter { $0.status == .pending }.count }
    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }
    var cancelledCount: Int { items.filter { $0.status == .cancelled }.count }
    var runningItem: BatchItem? { items.first { $0.status == .running } }
    /// 只读探针：当前是否还有本 Store 启动且仍在跑的子进程（下载 worker 或 ffmpeg）。
    var hasLiveChild: Bool { process?.isRunning ?? false }
    var totalCount: Int { items.count }

    var canImport: Bool {
        !libraryUnwritable && selectedCollection != nil && !(preview?.links.isEmpty ?? true)
    }

    // MARK: - 导入与收集文件夹

    func paste() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            notice = "剪贴板里没有文本。"
            return
        }
        inputText = inputText.isEmpty ? value : inputText + "\n" + value
        error = nil
        notice = "已粘贴一段文本，可继续粘贴或再导入文件。"
    }

    func importTextFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.utf8PlainText, .plainText, .commaSeparatedText, .data]
        panel.prompt = "导入文本"
        panel.message = "选择 UTF-8 文本或 CSV；链接按纯文本提取，不做列映射。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 5 * 1024 * 1024 else {
                error = "文件 \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) 超过 5 MiB 上限，已拒绝导入（不会截断后导入）。"
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                error = "不是 UTF-8 文本，请先用记事本/文本编辑转成 UTF-8 再导入。"
                return
            }
            inputText = inputText.isEmpty ? text : inputText + "\n" + text
            error = nil
            notice = "已读入 \(url.lastPathComponent)，确认后点「加入队列」。"
        } catch {
            self.error = "读取文件失败：\(error.localizedDescription)"
        }
    }

    func chooseParentFolder() {
        guard !isRunning else { return }
        choosingParentFolder = true
    }

    @discardableResult
    func createCollection(parentID: UUID? = nil, notes: String = "") -> Bool {
        guard organizationAvailable() else { return false }
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            error = "请先填写收集文件夹名称（不能是「.」或「..」，也不能包含斜杠）。"
            return false
        }
        do {
            try CollectionOrganization.validateParent(parentID, for: nil, in: collections)
            let savedNotes = try CollectionOrganization.editedNotes(notes)
            let parent = parentID.flatMap { id in collections.first { $0.id == id }.map { URL(fileURLWithPath: $0.path) } }
                ?? URL(fileURLWithPath: parentFolder)
            var created = try BatchRepository.createCollection(
                name: name,
                parent: parent,
                existing: collections)
            created.parentID = parentID; created.notes = savedNotes
            let previous = collections
            collections.append(created)
            guard persist() else {
                collections = previous
                if rmdir(created.path) != 0 && errno != ENOENT { error = (error ?? "保存失败。") + "新目录仍保留在：\(created.path)" }
                return false
            }
            selectedCollectionID = created.id
            notesDraft = created.notes
            newCollectionName = ""
            error = nil
            notice = "已创建收集文件夹：\(created.name)"
            return true
        } catch {
            self.error = "创建收集文件夹失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Register a directory chosen in the shared in-app picker; never move or recreate it.
    @discardableResult
    func useDestination(_ path: String) -> Bool {
        guard !isRunning, !libraryUnwritable else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              directory.boolValue, FileManager.default.isWritableFile(atPath: url.path) else {
            error = "保存目录无法写入，请选择现有可写文件夹。"; return false
        }
        if let existing = collections.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL == url }) {
            selectCollection(existing.id); return true
        }
        var created = StudyCollection(name: url.lastPathComponent, path: url.path)
        created.parentID = collections.filter { url.path.hasPrefix($0.path + "/") }
            .max(by: { $0.path.count < $1.path.count })?.id
        collections.append(created)
        guard persist() else { collections.removeLast(); return false }
        selectCollection(created.id)
        return true
    }

    func selectCollection(_ id: UUID) {
        selectedCollectionID = id
        notesDraft = selectedCollection?.notes ?? ""
        error = nil
    }

    func saveNotes() {
        guard let folder = selectedCollection else {
            error = "请先选择一个收集文件夹。"
            return
        }
        _ = updateCollectionNotes(folder.id, notes: notesDraft)
    }

    private func organizationAvailable() -> Bool {
        guard !libraryUnwritable else {
            if error == nil { error = "资料库尚不可写。请保留输入内容，修复资料库或移动恢复记录后重新打开App。" }
            return false
        }
        guard !isRunning && !hasLiveChild else { error = "队列正在处理媒体，请等当前任务结束或暂停队列后整理文件夹。"; return false }
        return true
    }

    @discardableResult
    func updateCollectionNotes(_ id: UUID, notes: String) -> Bool {
        guard organizationAvailable() else { return false }
        guard let index = collections.firstIndex(where: { $0.id == id }) else { error = "文件夹已不存在，请重新选择。"; return false }
        do {
            let saved = try CollectionOrganization.editedNotes(notes), previous = collections
            collections[index].notes = saved
            guard persist() else { collections = previous; return false }
            if selectedCollectionID == id { notesDraft = saved }
            error = nil; notice = "学习备注已保存。"; return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func moveCollection(_ id: UUID, to parent: UUID?) -> Bool {
        guard organizationAvailable() else { return false }
        var state = BatchLibraryState(); state.collections = collections; state.items = items; state.imports = imports
        do {
            let moved = try repository.moveCollection(id, to: parent, rootDirectory: URL(fileURLWithPath: parentFolder), expected: state)
            if let source = state.collections.first(where: { $0.id == id })?.path,
               let destination = moved.collections.first(where: { $0.id == id })?.path {
                lastCollectionMove = CollectionRelocation(source: source, destination: destination)
            }
            collections = moved.collections; items = moved.items
            error = nil; notice = "真实文件夹已移动，视频和音轨路径已同步更新。"; return true
        } catch {
            self.error = error.localizedDescription
            if FileManager.default.fileExists(atPath: repository.moveJournalURL.path) { libraryUnwritable = true }
            return false
        }
    }

    func reorderCollection(_ id: UUID, by offset: Int) {
        guard organizationAvailable() else { return }
        let previous = collections
        CollectionOrganization.reorder(id, by: offset, in: &collections)
        guard collections != previous else { return }
        guard persist() else { collections = previous; return }
        error = nil; notice = "文件夹显示顺序已保存。"
    }

    func enqueue() {
        guard !libraryUnwritable else { return }
        guard let collection = selectedCollection else {
            error = "请先选择或创建一个收集文件夹，再加入队列。"
            return
        }
        let source = inputText
        let parsed: BatchImportPreview
        do {
            parsed = try BatchLinkParser.preview(source, existing: Set(existingLinks))
        } catch {
            self.error = "解析失败：\(error.localizedDescription)"
            return
        }
        guard !parsed.links.isEmpty else {
            error = "没有可加入的新链接（重复 \(parsed.duplicateCount) 条、无效 \(parsed.invalidCount) 条）。"
            return
        }
        let snapshotQuality = quality
        let snapshotAudio = includeAudio
        // 全文每批只存一次进 imports；每条 item 只带 importID 引用 + 原始行摘录，
        // 否则 5000 条 × 5 MiB 会把资料库撑到 25 GiB。
        let batch = BatchImportSource(collectionID: collection.id, text: source)
        imports.append(batch)
        for link in parsed.links {
            var item = BatchItem(collectionID: collection.id, link: link,
                                 sourceText: excerpt(for: link, in: parsed, fallback: source),
                                 qualityRaw: snapshotQuality.rawValue)
            item.importID = batch.id
            item.wantsAudio = snapshotAudio
            items.append(item)
        }
        guard persist() else {
            items.removeLast(parsed.links.count)
            imports.removeLast()
            notice = nil
            return
        }
        notice = "已加入 \(parsed.links.count) 条到「\(collection.name)」"
            + "（跳过重复 \(parsed.duplicateCount) 条，无效行 \(parsed.invalidCount) 条）。"
            + (snapshotAudio ? "已勾选配套音轨，" : "")
            + "点「开始队列」才会联网。"
        inputText = ""
        error = nil
    }

    /// 博主采集的受控入队。不经过文本导入的 5000 条上限，也不把主页结果伪装成用户粘贴的大段文本。
    /// 先全部校验并去重，只持久化一次；调用方要求开始时才启动现有队列。
    @discardableResult
    func enqueueCreatorPosts(_ posts: [CreatorPost], sourceURL: String, singleBusy: Bool, startImmediately: Bool,
                             subscriptionTarget: UUID? = nil, subscriptionKnown: Set<String>? = nil,
                             subscriptionQuality: Quality? = nil, subscriptionAudio: Bool? = nil) -> Int {
        guard !libraryUnwritable else { return 0 }
        if singleBusy {
            error = "单条下载进行中，请等它结束后再把博主筛选结果加入队列。"
            return 0
        }
        if isRunning || process != nil {
            error = "批量队列正在运行，请等它结束后再加入博主筛选结果。"
            return 0
        }
        guard let collection = (subscriptionTarget == nil ? selectedCollection : collections.first { $0.id == subscriptionTarget }) else {
            error = "请先选择或创建一个收集文件夹，再加入队列。"
            return 0
        }
        let source = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotQuality = subscriptionQuality ?? quality
        let snapshotAudio = subscriptionAudio ?? includeAudio
        var seen = subscriptionKnown ?? Set(items.filter { $0.collectionID == collection.id }.flatMap { item in
            [BatchLinkParser.identity(for: item.link, videoID: item.videoID), BatchLinkParser.identity(for: item.link)].compactMap { $0 }
        })
        var accepted: [BatchItem] = []
        var skippedDuplicate = 0
        var skippedInvalid = 0
        var cursor = posts.startIndex
        while cursor < posts.endIndex {
            let end = posts.index(cursor, offsetBy: 1000, limitedBy: posts.endIndex) ?? posts.endIndex
            for post in posts[cursor..<end] {
                guard let acceptedLink = acceptedCreatorLink(post),
                      let identity = BatchLinkParser.identity(for: acceptedLink, videoID: post.id) else {
                    skippedInvalid += 1
                    continue
                }
                if seen.contains(identity) {
                    skippedDuplicate += 1
                    continue
                }
                seen.insert(identity)
                var item = BatchItem(collectionID: collection.id,
                                     link: acceptedLink,
                                     sourceText: clip(source.isEmpty ? acceptedLink : source),
                                     qualityRaw: snapshotQuality.rawValue)
                item.wantsAudio = snapshotAudio
                item.videoID = post.id
                item.platformRaw = BatchLinkParser.platformRaw(from: acceptedLink)
                if !post.title.isEmpty { item.title = post.title }
                item.author = post.author
                item.creatorPublishedAt = post.createdAt
                item.creatorDiggCount = post.diggCount
                item.creatorCollectCount = post.collectCount
                item.creatorSourceURL = source.isEmpty ? nil : source
                accepted.append(item)
            }
            cursor = end
        }
        guard !accepted.isEmpty else {
            error = "没有可加入的新视频（重复 \(skippedDuplicate) 条，无效 \(skippedInvalid) 条）。"
            return 0
        }
        items.append(contentsOf: accepted)
        guard persist() else {
            items.removeLast(accepted.count)
            notice = nil
            return 0
        }
        error = nil
        notice = "已加入 \(accepted.count) 条博主视频到「\(collection.name)」"
            + "（跳过重复 \(skippedDuplicate) 条，无效 \(skippedInvalid) 条）。"
            + (snapshotAudio ? "已勾选配套音轨。" : "")
            + (startImmediately ? "开始下载。" : "点「开始队列」才会联网。")
        if startImmediately { start(only: subscriptionKnown == nil ? nil : Set(accepted.map(\.id))) }
        return accepted.count
    }

    /// 平台、作品编号与规范链接必须指向同一作品；不能把其它平台拼成抖音URL。
    private func acceptedCreatorLink(_ post: CreatorPost) -> String? {
        guard post.isVideo else { return nil }
        let id = post.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 256 else { return nil }
        var link = post.link.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.isEmpty, id.count == 19, id.allSatisfy(\.isNumber) {
            link = "https://www.douyin.com/video/\(id)"
        }
        guard let canonical = BatchLinkParser.normalize(link),
              BatchLinkParser.videoID(from: canonical) == id else { return nil }
        if let platform = post.platformRaw, platform != BatchLinkParser.platformRaw(from: canonical) { return nil }
        return canonical
    }

    // MARK: - 队列控制

    func start(only scope: Set<UUID>? = nil) {
        guard !otherTaskIsBusy() else { return }
        guard !libraryUnwritable else { return }
        guard process == nil else { return }
        guard pendingCount > 0 || !audioOnlyQueue.isEmpty else {
            notice = "队列里没有待处理任务。"
            return
        }
        runScope = scope
        isPaused = false
        isRunning = true
        pump()
    }

    func pause() {
        guard isRunning else { return }
        isPaused = true
        detail = "已请求暂停：当前这条完成后停止。"
        notice = "暂停已生效于队列，不中断正在下载的这一条。"
    }

    func resume() {
        guard !otherTaskIsBusy() else { return }
        guard !libraryUnwritable else { return }
        guard isPaused else { return }
        isPaused = false
        isRunning = true
        pump()
    }

    func cancelCurrent() {
        guard let running = process else { return }
        cancelRequested = true
        detail = "正在取消当前任务…"
        if running.isRunning { running.terminate() }
        isPaused = true
        isRunning = true
    }

    func retryFailed() {
        reset(statuses: [.failed, .cancelled], ids: nil)
    }

    func retry(_ id: UUID) {
        reset(statuses: nil, ids: [id])
    }

    private func reset(statuses: Set<BatchStatus>?, ids: Set<UUID>?) {
        guard !libraryUnwritable else { return }
        var changed = 0
        for index in items.indices {
            let status = items[index].status
            guard status == .failed || status == .cancelled else { continue }
            if let ids, !ids.contains(items[index].id) { continue }
            if let statuses, !statuses.contains(status) { continue }
            items[index].status = .pending
            items[index].error = nil
            changed += 1
        }
        guard changed > 0 else {
            notice = "没有可重试的失败或已取消任务（已完成的任务不受影响）。"
            return
        }
        notice = "已把 \(changed) 条重置为待处理；点「开始队列」才会重试，已完成记录保持不变。"
        persist()
    }

    func exportSelected() {
        guard let collection = selectedCollection else {
            error = "请先选择一个收集文件夹。"
            return
        }
        do {
            let url = try BatchRepository.export(
                collection: collection,
                items: items.filter { $0.collectionID == collection.id },
                imports: imports.filter { $0.collectionID == collection.id })
            notice = "已导出学习资料到：\(url.path)"
            error = nil
        } catch {
            self.error = "导出失败：\(error.localizedDescription)"
        }
    }

    func openSelectedFolder() {
        guard let collection = selectedCollection else {
            error = "请先选择一个收集文件夹。"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: collection.path))
    }

    func play(_ item: BatchItem) {
        if item.isAlbum { viewingAlbum = item; return }
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else {
            error = "本地文件不存在，可能已被移动；可用「复制原链接」重新入队。"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func reveal(_ item: BatchItem) {
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else {
            error = "本地文件不存在，无法在 Finder 中显示。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 已保存视频但缺音轨的条数，与视频失败数 `failedCount` 分开统计。
    var audioMissingCount: Int {
        items.filter { $0.status == .completed && !$0.isAlbum && $0.wantsAudio && $0.audioPath == nil }.count
    }

    /// 只对已保存的视频在本地补导出一条音轨：不重新下载、不覆盖已有文件。
    func exportAudio(_ id: UUID) {
        guard !libraryUnwritable else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            error = "找不到这条任务。"
            return
        }
        let item = items[index]
        if item.isAlbum { notice = "图文作品已保存为图片，不需要导出视频音轨。"; return }
        guard item.status == .completed else {
            error = "这条任务还没有已保存的视频，不能只补音轨（不会替你重新下载）。"
            return
        }
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else {
            error = "找不到这条任务的视频文件，无法导出音轨。"
            return
        }
        if let audioPath = item.audioPath {
            notice = "这条已有配套音轨：\((audioPath as NSString).lastPathComponent)"
            return
        }
        items[index].wantsAudio = true
        items[index].audioError = nil
        persist()
        if !audioOnlyQueue.contains(id) { audioOnlyQueue.append(id) }
        if process == nil, !isPaused {
            isRunning = true
            pump()
        } else {
            notice = "已排队，等当前任务结束后在本地补导出这条音轨。"
        }
    }

    /// 补导出范围＝当前主题（未选主题时为全部主题），同样走这条串行队列。
    func exportMissingAudio() {
        guard !libraryUnwritable else { return }
        let scoped = selectedCollectionID.map { id in items.filter { $0.collectionID == id } } ?? items
        let targets = scoped.filter { item in
            item.status == .completed
                && !item.isAlbum && item.audioPath == nil
                && (item.path.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        }
        guard !targets.isEmpty else {
            notice = "没有需要补导出的音轨（已完成且文件在位的条目才会计入，不会重新下载）。"
            return
        }
        for item in targets {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].wantsAudio = true
                items[index].audioError = nil
            }
            if !audioOnlyQueue.contains(item.id) { audioOnlyQueue.append(item.id) }
        }
        notice = "已排入 \(targets.count) 条本地补导出音轨，不重新下载视频。"
        persist()
        if process == nil, !isPaused {
            isRunning = true
            pump()
        }
    }

    func playAudio(_ item: BatchItem) {
        guard let path = item.audioPath, FileManager.default.fileExists(atPath: path) else {
            error = "这条任务还没有可用的配套音轨，可点「补导出缺失音轨」。"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealAudio(_ item: BatchItem) {
        guard let path = item.audioPath, FileManager.default.fileExists(atPath: path) else {
            error = "这条任务还没有可用的配套音轨，无法在 Finder 中显示。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 退出时只终止本 Store 启动的 worker；运行中的条目留待下次启动恢复为待处理。
    func shutdown() {
        guard let running = process, running.isRunning else { return }
        cancelRequested = true
        running.terminate()
        discardStaging()
    }

    // MARK: - 顺序 pump

    private func pump() {
        guard process == nil, !isPaused, !libraryUnwritable else { return }
        guard let index = items.firstIndex(where: { $0.status == .pending && (runScope?.contains($0.id) ?? true) }) else {
            // 没有待下载条目时，同一条串行队列接着消化排队的「仅补音轨」任务。
            while runScope == nil, let next = audioOnlyQueue.first {
                audioOnlyQueue.removeFirst()
                if let position = items.firstIndex(where: { $0.id == next }),
                   items[position].status == .completed,
                   items[position].audioPath == nil {
                    isRunning = true
                    runTotal = 0
                    runAudioStep(for: next)
                    return
                }
            }
            finishQueue()
            return
        }
        // 分子和分母都按本轮实际处理范围计数，历史记录及范围外待处理不参与。
        if runTotal == 0 {
            runDone = 0
            runTotal = items.filter { $0.status == .pending && (runScope?.contains($0.id) ?? true) }.count
        }
        guard let collection = collections.first(where: { $0.id == items[index].collectionID }) else {
            items[index].status = .failed
            items[index].error = "找不到所属收集文件夹，已记为失败。"
            completeEntry()
            return
        }
        let item = items[index]
        guard let worker = BatchStore.workerOverrideURL
                ?? Bundle.main.resourceURL?.appendingPathComponent("worker/拾影Worker"),
              FileManager.default.isExecutableFile(atPath: worker.path) else {
            items[index].status = .failed
            items[index].error = "下载组件缺失，请重新安装 App。"
            error = "下载组件缺失，队列已停止。"
            persist()
            finishQueue()
            return
        }
        let entry = item.id
        generation = UUID()
        let token = generation
        entryID = entry
        phase = .video
        cancelRequested = false
        reuseDonor = nil
        lastComplete = nil
        lastItemError = nil
        lastStatistics = nil
        items[index].status = .running
        items[index].error = nil
        detail = runDetail("正在解析 \(item.title)")
        progress = queueProgress(current: 0)

        let process = Process()
        process.executableURL = worker
        process.arguments = ["download", "--link", item.link, "--quality", item.qualityRaw,
                             "--folder", collection.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let session = CreatorStore.sessionForDownload(link: item.link)
        let sessionPipe = session.map { _ in Pipe() }
        if let sessionPipe { process.arguments! += ["--session-stdin"]; process.standardInput = sessionPipe }
        self.process = process
        persist()
        do {
            try process.run()
        } catch {
            self.process = nil
            items[index].status = .failed
            items[index].error = "下载组件启动失败：\(error.localizedDescription)"
            self.error = "下载组件启动失败，队列已停止。"
            persist()
            finishQueue()
            return
        }
        if let session, let sessionPipe {
            DispatchQueue.global(qos: .utility).async {
                defer { try? sessionPipe.fileHandleForWriting.close() }
                do { try sessionPipe.fileHandleForWriting.write(contentsOf: session) }
                catch { if process.isRunning { process.terminate() } }
            }
        }
        // 启动前那一步里用户可能已经点了取消：这里补一次，取消不会落空。
        if cancelRequested { process.terminate() }

        DispatchQueue.global(qos: .utility).async { _ = stderr.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { self.handle(event, entry: entry, token: token) }
                    }
                }
            }
            process.waitUntilExit()
            DispatchQueue.main.async { self.finishVideo(entry: entry, token: token, code: process.terminationStatus) }
        }
    }

    // MARK: - 事件处理（按 entry + generation 隔离旧回调）

    /// 事件入口。entry + generation 双校验：同一条目重试后，上一轮的迟到回调会被 token 挡掉。
    /// internal 而非 private 只为测试宿主能注入陈旧事件验证这条守卫，正式包不会直接调用。
    func handle(_ event: [String: Any], entry: UUID, token: UUID) {
        guard entryID == entry, token == generation,
              let index = items.firstIndex(where: { $0.id == entry }),
              items[index].status == .running else { return }
        switch event["event"] as? String {
        case "metadata":
            lastStatistics = nil
            if MediaPlatform.detect(link: items[index].link) == .wechat,
               let raw = event["statistics"], let data = try? JSONSerialization.data(withJSONObject: raw),
               let value = try? JSONDecoder().decode(WorkStatistics.self, from: data), value.valid {
                lastStatistics = value
            }
            if let id = event["id"] as? String { items[index].videoID = id }
            if let title = event["title"] as? String, !title.isEmpty { items[index].title = title }
            if let author = event["author"] as? String { items[index].author = author }
            if let description = event["description"] as? String { items[index].description = description }
            if let kind = event["mediaKind"] as? String { items[index].mediaKind = kind }
            if let duration = event["duration"] as? Double { items[index].duration = duration }
            detail = runDetail(items[index].title.isEmpty ? "正在解析" : "正在处理：\(items[index].title)")
            if let donor = reusableDonor(for: items[index], at: index) {
                reuseDonor = donor
                persist()
                process?.terminate()
            } else {
                persist()
            }
        case "progress":
            if !cancelRequested {
                if let stageDetail = event["detail"] as? String {
                    detail = runDetail(stageDetail)
                }
                if let fraction = event["progress"] as? Double {
                    progress = queueProgress(current: min(1, max(0, fraction)))
                }
            }
        case "complete":
            lastComplete = event
        case "error":
            lastItemError = event["message"] as? String ?? "下载失败，请重试。"
            items[index].error = lastItemError
        case "cancelled":
            break
        default:
            break
        }
    }

    private func finishVideo(entry: UUID, token: UUID, code: Int32) {
        guard phase == .video, entryID == entry, token == generation,
              let index = items.firstIndex(where: { $0.id == entry }) else { return }
        process = nil
        var item = items[index]
        let donor = reuseDonor
        let complete = lastComplete

        if let donor {
            item.status = .completed
            item.path = donor.path
            item.mediaKind = donor.mediaKind
            item.imagePaths = donor.imagePaths
            item.width = donor.width
            item.height = donor.height
            item.bytes = donor.bytes
            if item.duration == 0 { item.duration = donor.duration }
            item.error = nil
            // 同 videoID 的媒体一起复用：音轨已导出就不再跑第二遍本地 ffmpeg。
            item.audioPath = donor.audioPath
            item.audioError = donor.audioError
            notice = "「\(item.title)」与已完成条目的 videoID 相同，已复用同一本地文件，没有重复下载。"
        } else if code == 0, let complete {
            item.status = .completed
            item.path = complete["path"] as? String
            item.mediaKind = complete["mediaKind"] as? String ?? item.mediaKind
            item.imagePaths = complete["imagePaths"] as? [String]
            item.width = complete["width"] as? Int ?? item.width
            item.height = complete["height"] as? Int ?? item.height
            item.bytes = (complete["bytes"] as? NSNumber)?.int64Value ?? item.bytes
            item.duration = complete["duration"] as? Double ?? item.duration
            if let video = complete["video"] as? [String: Any] {
                if let id = video["id"] as? String { item.videoID = id }
                if let description = video["description"] as? String { item.description = description }
            }
            item.error = nil
        } else if cancelRequested {
            item.status = .cancelled
            item.error = nil
        } else if complete != nil {
            item.status = .failed
            item.error = "收到完成事件但进程退出码为 \(code)，为不误导统计已记为失败。"
        } else {
            item.status = .failed
            item.error = lastItemError ?? "下载未完成（退出码 \(code)）。"
        }

        items[index] = item
        reuseDonor = nil
        lastComplete = nil
        lastItemError = nil
        persist()

        if !libraryUnwritable, item.status == .completed, let id = item.videoID, let value = lastStatistics,
           MediaPlatform.detect(link: item.link) == .wechat {
            var post = CreatorPost(id: id, link: item.link, title: item.title, author: item.author, isVideo: true)
            post.statistics = value
            onStatistics?(post)
        }
        lastStatistics = nil

        if item.status == .completed, !item.isAlbum, item.wantsAudio, item.audioPath == nil {
            // 视频完成后不释放 isRunning：同一条接着走本地音轨步骤，中间不排别的 worker。
            runAudioStep(for: entry)
        } else {
            completeEntry()
        }
    }

    // MARK: - 配套音轨（纯本地，不再联网）

    private func runAudioStep(for entry: UUID) {
        guard let index = items.firstIndex(where: { $0.id == entry }) else { completeEntry(); return }
        guard !items[index].isAlbum else { completeEntry(); return }
        guard let videoPath = items[index].path,
              FileManager.default.fileExists(atPath: videoPath) else {
            items[index].audioError = "找不到已保存的视频文件，无法导出音轨（不会重新下载）。"
            notice = "视频已保存，音轨导出失败：找不到视频文件。"
            persist()
            completeEntry()
            return
        }
        guard let tools = BatchStore.toolsDirectoryOverride
                ?? Bundle.main.resourceURL?.appendingPathComponent("Tools"),
              FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) else {
            items[index].audioError = "找不到随 App 打包的 ffmpeg，音轨未导出；视频文件已保留。"
            notice = "视频已保存，音轨导出失败：缺少打包的 ffmpeg。"
            persist()
            completeEntry()
            return
        }
        entryID = entry
        generation = UUID()
        let token = generation
        phase = .audio
        cancelRequested = false
        detail = runDetail("正在导出配套音轨：\((videoPath as NSString).lastPathComponent)")

        if !hasAudioStream(videoPath, tools: tools) {
            items[index].audioError = "源视频不含音轨，无法导出配套 M4A；视频文件已保留。"
            notice = "视频已保存，音轨导出失败：源视频没有音轨。"
            persist()
            completeEntry()
            return
        }

        let directory = URL(fileURLWithPath: videoPath).deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".shiying-audio-\(String(UUID().uuidString.prefix(8))).m4a")
        stagingAudio = staging
        let ffmpeg = Process()
        ffmpeg.executableURL = tools.appendingPathComponent("ffmpeg")
        ffmpeg.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error",
                            "-i", videoPath, "-map", "0:a:0", "-vn",
                            "-c:a", "aac", "-b:a", "160k", staging.path]
        let stderr = Pipe()
        ffmpeg.standardError = stderr
        ffmpeg.standardOutput = FileHandle.nullDevice
        process = ffmpeg
        do {
            try ffmpeg.run()
        } catch {
            process = nil
            stagingAudio = nil
            if let position = items.firstIndex(where: { $0.id == entry }) {
                items[position].audioError = "音轨导出启动失败：\(error.localizedDescription)；视频文件已保留。"
            }
            phase = .video
            persist()
            completeEntry()
            return
        }
        // 同一条启动窗口：取消可能落在 run 之前，这里补一次，音轨取消不会落空。
        if cancelRequested { ffmpeg.terminate() }
        DispatchQueue.global(qos: .utility).async { _ = stderr.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .userInitiated).async {
            ffmpeg.waitUntilExit()
            DispatchQueue.main.async {
                self.finishAudio(entry: entry, token: token, code: ffmpeg.terminationStatus,
                                 staging: staging, child: ffmpeg)
            }
        }
    }

    /// internal 而非 private：测试宿主需要直接注入一轮「迟到的音轨回调」验证隔离，正式包不会直接调用。
    /// staging/child 由发起方捕获传入：迟到的旧一轮回调只能处置自己的临时件与自己的子进程，
    /// 绝不清 `stagingAudio` / `process` 这些已经属于新一轮的共享状态。
    func finishAudio(entry: UUID, token: UUID, code: Int32, staging: URL, child: Process) {
        guard phase == .audio, entryID == entry, token == generation,
              let index = items.firstIndex(where: { $0.id == entry }) else {
            if child.isRunning { child.terminate() }
            try? FileManager.default.removeItem(at: staging)
            return
        }
        process = nil
        phase = .video
        if stagingAudio == staging { stagingAudio = nil }
        var item = items[index]

        if cancelRequested {
            try? FileManager.default.removeItem(at: staging)
            item.audioError = "音轨导出已取消；视频文件保留，可用「补导出缺失音轨」重试。"
        } else if code != 0 || !FileManager.default.fileExists(atPath: staging.path) {
            try? FileManager.default.removeItem(at: staging)
            item.audioError = "音轨导出失败（ffmpeg 退出码 \(code)，常见原因是源视频没有音轨流）；视频文件已保留。"
        } else if let videoPath = item.path, let problem = audioProblem(video: videoPath, staging: staging) {
            try? FileManager.default.removeItem(at: staging)
            item.audioError = "\(problem)；视频文件已保留。"
        } else if let videoPath = item.path {
            let target = publishTarget(for: videoPath, staging: staging)
            do {
                try FileManager.default.moveItem(at: staging, to: target)
                item.audioPath = target.path
                item.audioError = nil
            } catch {
                try? FileManager.default.removeItem(at: staging)
                item.audioError = "音轨发布失败：\(error.localizedDescription)；视频文件已保留。"
            }
        } else {
            try? FileManager.default.removeItem(at: staging)
            item.audioError = "找不到对应视频路径，未发布音轨。"
        }

        if let audioPath = item.audioPath {
            notice = "已导出配套音轨：\((audioPath as NSString).lastPathComponent)"
        } else if let audioError = item.audioError {
            notice = "视频已保存，音轨导出失败：\(audioError)"
        }
        items[index] = item
        persist()
        completeEntry()
    }

    private func completeEntry() {
        runDone += 1
        progress = queueProgress(current: 0)
        persist()
        if isPaused {
            isRunning = false
            detail = "已暂停，待处理 \(pendingCount) 条。"
            runTotal = 0
            runDone = 0
        } else {
            pump()
        }
    }

    private func toolsDirectory() -> URL? {
        BatchStore.toolsDirectoryOverride
            ?? Bundle.main.resourceURL?.appendingPathComponent("Tools")
    }

    /// 发布前的强制验证：必须确认提取结果真有音频流，且时长与视频一致。
    /// 任何探测失败都返回错误文字（不发布、保留视频），不把「无法验证」当成通过。
    private func audioProblem(video: String, staging: URL) -> String? {
        guard let tools = toolsDirectory(),
              FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffprobe").path) else {
            return "缺少 ffprobe，无法验证音轨完整性，未发布"
        }
        guard let videoSeconds = probeDuration(video, tools: tools), videoSeconds > 0 else {
            return "ffprobe 读取视频时长失败，未发布"
        }
        let streams = probeJSON(staging.path, tools: tools,
                                arguments: ["-select_streams", "a:0", "-show_entries", "stream=codec_type"])
        guard let list = streams?["streams"] as? [[String: Any]],
              list.contains(where: { ($0["codec_type"] as? String) == "audio" }) else {
            return "提取结果不含音频流，未发布"
        }
        guard let audioSeconds = probeDuration(staging.path, tools: tools), audioSeconds > 0 else {
            return "ffprobe 读取音轨时长失败，未发布"
        }
        let tolerance = max(2, videoSeconds * 0.01)
        guard abs(videoSeconds - audioSeconds) <= tolerance else {
            return String(format: "音轨时长与视频不一致（视频 %.1f 秒，音轨 %.1f 秒）",
                          videoSeconds, audioSeconds)
        }
        return nil
    }

    /// 只有 ffprobe 可用时才提前判断「源视频无音轨」，好给出准确提示；
    /// ffprobe 不可用时返回 true 继续尝试，由发布前的 audioProblem 兜底拒绝，绝不在这里放行。
    private func hasAudioStream(_ videoPath: String, tools: URL?) -> Bool {
        guard let tools,
              FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffprobe").path),
              let streams = probeJSON(videoPath, tools: tools,
                                      arguments: ["-select_streams", "a:0",
                                                  "-show_entries", "stream=codec_type"]) else {
            return true
        }
        guard let list = streams["streams"] as? [[String: Any]] else { return false }
        return list.contains { ($0["codec_type"] as? String) == "audio" }
    }

    private func probeDuration(_ path: String, tools: URL) -> Double? {
        guard let json = probeJSON(path, tools: tools,
                                   arguments: ["-show_entries", "format=duration"]) else { return nil }
        if let format = json["format"] as? [String: Any], let text = format["duration"] as? String {
            return Double(text)
        }
        if let streams = json["streams"] as? [[String: Any]],
           let first = streams.first, let text = first["duration"] as? String {
            return Double(text)
        }
        return nil
    }

    private func probeJSON(_ path: String, tools: URL, arguments: [String]) -> [String: Any]? {
        var full = ["-v", "error", "-of", "json"]
        full.append(contentsOf: arguments)
        full.append(path)
        let ffprobe = Process()
        ffprobe.executableURL = tools.appendingPathComponent("ffprobe")
        ffprobe.arguments = full
        let stdout = Pipe()
        ffprobe.standardOutput = stdout
        ffprobe.standardError = FileHandle.nullDevice
        guard (try? ffprobe.run()) != nil else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        ffprobe.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 与视频同 stem；目标已存在就加序号，moveItem 对已存在目标会失败，因此不会覆盖用户文件。
    private func publishTarget(for videoPath: String, staging: URL) -> URL {
        let video = URL(fileURLWithPath: videoPath)
        let directory = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(stem + ".m4a")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path), index < 1000 {
            candidate = directory.appendingPathComponent("\(stem)-\(index).m4a")
            index += 1
        }
        return candidate
    }

    private func discardStaging() {
        if let staging = stagingAudio {
            try? FileManager.default.removeItem(at: staging)
            stagingAudio = nil
        }
    }

    private func finishQueue() {
        runScope = nil
        process = nil
        isRunning = false
        isPaused = false
        runTotal = 0
        runDone = 0
        progress = 1
        detail = "队列已结束：完成 \(completedCount) 条，失败 \(failedCount) 条，已取消 \(cancelledCount) 条。"
    }

    // MARK: - 小工具

    private var existingLinks: [String] {
        items.filter { $0.collectionID == selectedCollectionID }.map { $0.link }
    }

    /// A 的解析器负责 link→原始行映射；映射缺失时退回本批文本里第一条含该 link 的行。
    private func excerpt(for link: String, in preview: BatchImportPreview, fallback: String) -> String {
        if let mapped = preview.sourceTexts[link], !mapped.isEmpty { return clip(mapped) }
        let line = fallback.split(whereSeparator: { $0.isNewline })
            .first { $0.contains(link) } ?? ""
        return clip(String(line))
    }

    /// 按 UTF-8 字节上限截断，且不切开多字节字符（中文分享文案常见）。
    private func clip(_ text: String, limit: Int = 4096) -> String {
        var kept = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > limit { break }
            kept.append(character)
            bytes += size
        }
        return kept
    }

    /// 同 collection 内已有相同 videoID 且文件仍在，就复用它，不再下载第二份。
    private func reusableDonor(for item: BatchItem, at index: Int) -> BatchItem? {
        guard let videoID = item.videoID, !videoID.isEmpty else { return nil }
        return items.first { candidate in
            candidate.id != item.id
                && candidate.collectionID == item.collectionID
                && candidate.status == .completed
                && candidate.isAlbum == item.isAlbum
                && (!candidate.isAlbum || (candidate.imagePaths?.isEmpty == false && candidate.imagePaths!.allSatisfy { FileManager.default.fileExists(atPath: $0) }))
                && candidate.videoID == videoID
                && BatchLinkParser.platformRaw(from: candidate.link) == BatchLinkParser.platformRaw(from: item.link)
                && (candidate.path.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        }
    }

    private func runDetail(_ stage: String) -> String {
        guard runTotal > 0 else { return stage }
        return "本轮 \(runDone + 1)/\(runTotal) · \(stage)"
    }

    private func queueProgress(current: Double) -> Double {
        guard runTotal > 0 else { return current }
        return min(1, (Double(runDone) + current) / Double(runTotal))
    }

    private func matchesFilter(_ item: BatchItem) -> Bool {
        statusFilter == "全部" || item.status.rawValue == statusFilter || item.status.title == statusFilter
    }

    private func matchesSearch(_ item: BatchItem) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = item.title + item.author + item.description + item.link
        return haystack.localizedCaseInsensitiveContains(needle)
    }

    @discardableResult
    private func persist() -> Bool {
        guard !libraryUnwritable else { return false }
        // A 现在提供显式 init()，合成 memberwise init 不再存在，这里逐字段赋值最稳。
        var state = BatchLibraryState()
        state.collections = collections
        state.items = items
        state.imports = imports
        do {
            try repository.save(state)
            return true
        } catch {
            libraryUnwritable = true
            self.error = "资料库写入失败：\(error.localizedDescription)。后续不再写入，避免覆盖已有内容。"
            return false
        }
    }
}
