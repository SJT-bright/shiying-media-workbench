import Foundation
import Combine
import WebKit

@MainActor final class WorkStatisticsStore: ObservableObject {
    @Published private(set) var entries: [String: WorkStatisticsEntry] = [:]
    @Published private(set) var isUpdating = false
    @Published private(set) var lastChanges: [WorkStatisticsChange] = []
    @Published var showChangeSummary = false
    @Published var detail = ""
    @Published var error: String?
    @Published var notice: String?
    static var workerOverrideURL: URL?
    static var dataRootOverride: URL?
    private let repository: WorkStatisticsRepository
    private var blocked = false
    private var process: Process?
    private var generation = UUID()
    private var requested: Set<String> = []
    private var received: Set<String> = []
    private var sawTerminal = false
    private var cancelled = false
    private var deferredScan: [CreatorPost] = []
    private var baselineEntries: [String: WorkStatistics] = [:]
    private var pendingLabels: [String: String] = [:]
    private var changeMap: [String: WorkStatisticsChange] = [:]

    init() {
        let root = Self.dataRootOverride ?? shiyingTestDataRoot(fallback: "/tmp/shiying-metrics-test")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/拾影")
        repository = WorkStatisticsRepository(fileURL: root.appendingPathComponent("work-statistics.json"))
        do { entries = try repository.load().entries }
        catch { blocked = true; self.error = "作品统计读取失败，原文件保留，暂停统计写入：\(error.localizedDescription)" }
    }
    func entry(link: String, videoID: String? = nil) -> WorkStatisticsEntry? {
        WorkStatisticsRepository.id(link: link, videoID: videoID).flatMap { entries[$0] }
    }
    func change(link: String, videoID: String? = nil) -> WorkStatisticsChange? {
        WorkStatisticsRepository.id(link: link, videoID: videoID).flatMap { changeMap[$0] }
    }
    /// 仅在本次手动更新已经产生差异时展示；带箭头的汇总由界面弹出。
    private func recordChange(id: String, newValue: WorkStatistics, baseline: [String: WorkStatistics]? = nil, labels: [String: String]? = nil, publish: Bool) {
        let old = (baseline ?? baselineEntries)[id]
        let deltas = newValue.deltas(from: old)
        guard !deltas.isEmpty else { changeMap.removeValue(forKey: id); return }
        let title = (labels ?? pendingLabels)[id]
        changeMap[id] = WorkStatisticsChange(id: id, title: title, deltas: deltas)
        if publish { publishChanges() }
    }
    private func publishChanges() {
        lastChanges = changeMap.values.sorted { $0.impact != $1.impact ? $0.impact > $1.impact : $0.id < $1.id }
    }
    @discardableResult private func save(_ next: [String: WorkStatisticsEntry]) -> Bool {
        guard !blocked else { return false }
        do { try repository.save(WorkStatisticsLibrary(entries: next)); entries = next; return true }
        catch { blocked = true; self.error = "作品统计保存失败，显示和磁盘中的上次数据保留：\(error.localizedDescription)。请修复统计库后重新打开App。"; return false }
    }
    func adoptScan(_ posts: [CreatorPost]) {
        guard !blocked else { return }
        guard !isUpdating else { deferredScan = posts; return }
        var next = entries, count = 0
        var adopted: [(String, WorkStatistics, String)] = []
        let baseline = entries.compactMapValues { $0.value }
        for post in posts {
            guard let id = WorkStatisticsRepository.id(link: post.link, videoID: post.id),
                  let value = post.statistics, value.valid,
                  value.observedAt >= (next[id]?.value?.observedAt ?? 0) else { continue }
            var stored = value
            if let cover = post.cover, cover.hasPrefix("https://"), cover.count <= 2048 { stored.coverURL = cover }
            next[id] = WorkStatisticsEntry(value: stored, lastAttemptAt: stored.observedAt, issue: nil); count += 1
            adopted.append((id, stored, post.title))
        }
        if count > 0, save(next) {
            for (id, value, title) in adopted {
                recordChange(id: id, newValue: value, baseline: baseline, labels: [id: title], publish: false)
            }
            publishChanges()
            notice = "已同步本次采集的\(count)个作品统计，不下载视频。"; error = nil
        }
    }
    private func drainDeferredScan() {
        guard !deferredScan.isEmpty else { return }
        let posts = deferredScan, previousError = error, previousNotice = notice
        deferredScan = []; adoptScan(posts)
        // A simultaneous homepage scan must never hide the manual refresh failure.
        if let previousError { error = previousError }
        if let previousNotice, notice != previousNotice { notice = previousNotice + " " + (notice ?? "") }
    }
    private func failBeforeLaunch(_ message: String) {
        error = message; isUpdating = false; drainDeferredScan()
    }
    func refresh(_ ids: [String], skipped: Int = 0, homepages: [String: String] = [:]) {
        refresh(ids.compactMap { WorkStatisticsRepository.request(link: "https://www.douyin.com/video/" + $0, videoID: $0, homepage: homepages[$0]) }, skipped: skipped)
    }
    func refresh(_ requests: [WorkStatisticsRequest], skipped: Int = 0, labels: [String: String] = [:]) {
        guard !isUpdating else { return }
        guard !blocked else { error = "作品统计库不可写，请修复后重新打开App；上次数据保留。"; return }
        var unique: [String: WorkStatisticsRequest] = [:]
        for request in requests {
            guard WorkStatisticsRepository.validID(request.id), MediaPlatform.detect(link: request.link)?.rawValue == request.platform else {
                error = "作品来源与统计标识不一致，更新尚未开始。"; return
            }
            unique[request.id] = request
        }
        let works = unique.values.sorted { $0.id < $1.id }
        guard !works.isEmpty else { error = "没有可更新的抖音、视频号或B站作品；请检查记录中的分享链接和作品ID。"; return }
        guard works.count <= 5000 else { error = "共\(works.count)个作品，超过单次5000项。请进入子文件夹分批更新；本次未开始。"; return }
        requested = Set(works.map(\.id)); received = []; generation = UUID(); let token = generation
        baselineEntries = entries.compactMapValues { $0.value }
        pendingLabels = requests.reduce(into: [:]) { $0[$1.id] = $1.title }.merging(labels) { _, new in new }
        changeMap = [:]; lastChanges = []; showChangeSummary = false
        isUpdating = true; cancelled = false; sawTerminal = false; error = nil
        notice = skipped > 0 ? "\(skipped)条记录缺少有效分享链接、作品ID或暂不支持统计，已跳过。" : nil
        syncSessions(Array(Set(works.compactMap { MediaPlatform(rawValue: $0.platform) })).sorted { $0.rawValue < $1.rawValue }, sessions: [:], works: works, token: token)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == token, self.isUpdating, self.process == nil else { return }
            self.generation = UUID()
            self.failBeforeLaunch("读取内置登录超过10秒，更新尚未开始。请检查对应平台的内置网页后重试；已有数据保留。")
        }
    }
    private func syncSessions(_ platforms: [MediaPlatform], sessions: [String: Any], works: [WorkStatisticsRequest], token: UUID) {
        guard generation == token, isUpdating else { return }
        guard let platform = platforms.first else { start(works, sessions: sessions, token: token); return }
        detail = "正在同步拾影内置\(platform.title)登录…"
        let reader: (@escaping ([HTTPCookie]) -> Void) -> Void = CreatorStore.sessionCookieReaderOverride ?? { callback in CreatorLoginPersistence.dataStore(for: platform).httpCookieStore.getAllCookies { callback($0) } }
        reader { [weak self] cookies in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.isUpdating else { return }
                switch CreatorStore.sessionFromCookies(cookies, platform: platform) {
                case .failure(let issue): self.failBeforeLaunch("更新尚未开始：" + issue.message)
                case .success(let data):
                    var next = sessions
                    if let data = data ?? CreatorStore.sessionForWorker(platform: platform),
                       let object = try? JSONSerialization.jsonObject(with: data) {
                        // Captured media is unrelated to statistics. Only this platform's cookies enter stdin.
                        if platform == .douyin { next[platform.rawValue] = object }
                        else if let envelope = object as? [String: Any] { next[platform.rawValue] = ["version":1, "platform":platform.rawValue, "cookies":envelope["cookies"] ?? []] }
                    }
                    self.syncSessions(Array(platforms.dropFirst()), sessions: next, works: works, token: token)
                }
            }
        }
    }
    private func start(_ works: [WorkStatisticsRequest], sessions: [String: Any], token: UUID) {
        guard let resource = Self.workerOverrideURL ?? Bundle.main.resourceURL?.appendingPathComponent("worker/拾影Worker"), FileManager.default.isExecutableFile(atPath: resource.path) else {
            failBeforeLaunch("作品数据组件缺失，更新未开始。请重新安装完整App。"); return
        }
        let ids = works.map(\.id)
        guard let encoded = try? JSONEncoder().encode(works), let rows = try? JSONSerialization.jsonObject(with: encoded),
              let input = try? JSONSerialization.data(withJSONObject: ["version":2, "works":rows, "sessions":sessions]), input.count <= 1_048_576 else {
            failBeforeLaunch("作品更新请求超过1 MiB或无法编码，更新未开始。"); return
        }
        let child = Process(), output = Pipe(), stdin = Pipe()
        child.executableURL = resource; child.arguments = ["metrics"]; child.standardOutput = output
        child.standardError = FileHandle.nullDevice; child.standardInput = stdin
        process = child; detail = "已更新0/\(ids.count)个作品；只读取数据，不下载视频。"
        do { try child.run() }
        catch { process = nil; failBeforeLaunch("作品数据组件启动失败：\(error.localizedDescription)"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
            catch { child.terminate() }
            var buffer = Data()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                if buffer.count > 262_144 { child.terminate(); break }
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { [weak self] in guard let self, self.generation == token else { return }; self.consume(event, allowed: Set(ids)) }
                    }
                }
            }
            child.waitUntilExit()
            DispatchQueue.main.async { [weak self] in guard let self, self.generation == token else { return }; self.finish(code: child.terminationStatus) }
        }
    }
    // Public for the isolated native regression host; only requested identities are accepted.
    func consume(_ event: [String: Any], allowed: Set<String>) {
        switch event["event"] as? String {
        case "metrics_value", "metrics_failure":
            guard let id = event["id"] as? String, allowed.contains(id), WorkStatisticsRepository.validID(id) else { return }
            var next = entries, record = next[id] ?? WorkStatisticsEntry()
            if event["event"] as? String == "metrics_value", let object = event["statistics"], let data = try? JSONSerialization.data(withJSONObject: object),
               let value = try? JSONDecoder().decode(WorkStatistics.self, from: data), value.valid {
                if value.observedAt < (record.value?.observedAt ?? 0) { return }
                record.value = value; record.issue = nil; record.lastAttemptAt = value.observedAt
            } else if event["event"] as? String == "metrics_failure", let message = event["message"] as? String {
                record.issue = String(message.prefix(2000)); record.lastAttemptAt = Int64(Date().timeIntervalSince1970)
            } else { return }
            next[id] = record
            guard save(next) else { process?.terminate(); return }
            if event["event"] as? String == "metrics_value", let value = record.value {
                recordChange(id: id, newValue: value, publish: true)
            }
            received.insert(id); detail = "已处理\(received.count)/\(allowed.count)个作品；失败保留上次数据。"
        case "metrics_complete":
            sawTerminal = true
            let failed = received.filter { entries[$0]?.issue != nil }.count, seconds = event["seconds"] as? Double ?? 0
            if event["total"] as? Int != requested.count || event["failed"] as? Int != failed {
                error = "更新组件汇总与实际作品结果不一致，已保存的逐条数据保留，请重试。"
            }
            publishChanges(); showChangeSummary = !received.isEmpty
            notice = "作品数据更新完成：成功\(received.count - failed)，失败\(failed)，耗时\(String(format: "%.1f", seconds))秒。" + (notice.map { " " + $0 } ?? "")
        case "error": error = event["message"] as? String ?? "更新组件返回了未说明原因的错误。"
        case "metrics_progress": if let text = event["detail"] as? String { detail = text }
        default: break
        }
    }
    private func finish(code: Int32) {
        process = nil; isUpdating = false
        defer { drainDeferredScan() }
        guard !blocked else { return }
        if cancelled {
            publishChanges(); showChangeSummary = !lastChanges.isEmpty
            notice = "更新已取消，已取得\(received.count)个作品的数据已保存，其余保留上次数据。"; return
        }
        if !sawTerminal || received != requested {
            error = (error.map { $0 + " " } ?? "") + "更新组件未完整返回：退出码\(code)，已处理\(received.count)/\(requested.count)。已取得的数据保留，其余可手动重试。"
        }
    }
    func cancel() {
        guard isUpdating else { return }
        cancelled = true; detail = "正在停止更新…"
        if let process { process.terminate() } else { generation = UUID(); isUpdating = false; notice = "更新已取消，作品数据保持。"; drainDeferredScan() }
    }
    func shutdown() { cancel() }
    var processedCount: Int { received.count }
    var failedCount: Int { received.filter { entries[$0]?.issue != nil }.count }
}
