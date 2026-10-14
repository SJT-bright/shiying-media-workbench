import Foundation
import Combine

@MainActor final class CreatorSubscriptionStore: ObservableObject {
    @Published private(set) var subscriptions: [CreatorSubscription] = []
    @Published private(set) var updatingID: UUID?
    @Published var message: String?
    @Published private(set) var issue: String?
    private let repository: CreatorSubscriptionRepository
    private var writable = true
    private var observation: AnyCancellable?
    private var cancelRequested = false
    var isUpdating: Bool { updatingID != nil }

    init(fileURL: URL? = nil) {
        let root = shiyingTestDataRoot(fallback: "/tmp/shiying-subscription-test")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/拾影")
        repository = CreatorSubscriptionRepository(fileURL: fileURL ?? root.appendingPathComponent("creator-subscriptions.json"))
        do { subscriptions = try repository.load().subscriptions }
        catch { writable = false; issue = "订阅库读取失败，原文件保留：" + error.localizedDescription }
    }

    func items(for platform: MediaPlatform) -> [CreatorSubscription] { subscriptions.filter { $0.platform == platform } }

    func current(_ creator: CreatorStore) -> CreatorSubscription? {
        subscriptions.first { $0.platform == creator.platform && $0.creatorID == creator.scannedCreatorID }
    }

    var canWrite: Bool { writable }

    @discardableResult
    private func commit(_ next: [CreatorSubscription]) -> Bool {
        guard writable else { return false }
        do {
            try repository.save(CreatorSubscriptionLibrary(subscriptions: next))
            subscriptions = next; issue = nil; return true
        } catch {
            writable = false
            issue = "订阅库保存失败，原文件保留：" + error.localizedDescription
            return false
        }
    }

    func subscribe(creator: CreatorStore, batch: BatchStore, store: Store) {
        guard writable, !isUpdating, !creator.isScanning, !store.busy, !batch.isRunning else { return }
        do {
            guard let creatorID = creator.scannedCreatorID, let homepage = creator.homepageURL,
                  !creator.creatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CreatorInputError(message: "先采集博主主页，取得博主名称后即可订阅。")
            }
            let canonical = try CreatorSubscriptionCore.homepage(platform: creator.platform, creatorID: creatorID, url: homepage.absoluteString)
            guard batch.useDestination(store.folder), let target = batch.selectedCollection else {
                throw CreatorInputError(message: batch.error ?? "请先选择保存目录。")
            }
            let item = CreatorSubscription(platform: creator.platform, creatorID: creatorID, homepage: canonical,
                                           name: creator.creatorName, collectionID: target.id,
                                           quality: batch.quality.rawValue, includeAudio: batch.includeAudio)
            var next = subscriptions
            if let i = next.firstIndex(where: { $0.identity == item.identity }) {
                next[i].name = item.name; next[i].collectionID = target.id
                next[i].quality = item.quality; next[i].includeAudio = item.includeAudio
            } else { next.append(item) }
            if commit(next) { message = "已订阅「\(item.name)」。点击更新即可下载仓库里缺少的视频。" }
        } catch { message = error.localizedDescription }
    }

    func remove(_ id: UUID) {
        guard !isUpdating else { return }
        if commit(subscriptions.filter { $0.id != id }) { message = "已取消订阅，下载记录和文件保留。" }
    }

    /// Use saved records and pending tasks across every destination, never historical 'seen' IDs.
    static func knownWorks(store: Store, batch: BatchStore) -> Set<String> {
        var known: Set<String> = []
        for record in store.records where record.status == "完成" && !record.isAlbum {
            guard let path = record.path, isFile(path) else { continue }
            known.formUnion([BatchLinkParser.identity(for: record.link, videoID: record.videoID),
                             BatchLinkParser.identity(for: record.link)].compactMap { $0 })
        }
        for item in batch.items where item.mediaKind != "video_cover" && item.mediaKind != "image_album" {
            guard item.status == .pending || item.status == .running || (item.status == .completed && item.path.map(isFile) == true) else { continue }
            known.formUnion([BatchLinkParser.identity(for: item.link, videoID: item.videoID),
                             BatchLinkParser.identity(for: item.link)].compactMap { $0 })
        }
        return known
    }

    private static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    func update(_ item: CreatorSubscription, creator: CreatorStore, batch: BatchStore, store: Store) {
        guard writable, !isUpdating, !creator.isScanning, !batch.isRunning, !store.busy else { return }
        guard batch.canWriteLibrary, !store.historyUnavailable, store.historyIssue == nil else {
            message = "资料库尚未正常读取，无法可靠检查已有作品，请先处理资料库错误。"; return
        }
        guard let target = batch.collections.first(where: { $0.id == item.collectionID }),
              FileManager.default.isWritableFile(atPath: target.path) else {
            message = "「\(item.name)」的保存目录不可用。选择新目录后，重新订阅该博主即可更新设置。"; return
        }
        updatingID = item.id; cancelRequested = false; message = "正在检查「\(item.name)」的新作品…"
        creator.selectPlatform(item.platform)
        creator.urlText = item.homepage
        // Observe settlement on the next main-loop turn, after finish() validates the terminal event.
        observation = creator.$isScanning.dropFirst().filter { !$0 }.receive(on: DispatchQueue.main)
            .sink { [weak self, weak creator, weak batch, weak store] _ in
                guard let self, let creator, let batch, let store, !creator.isScanning else { return }
                self.finishUpdate(item, creator: creator, batch: batch, store: store)
            }
        creator.scan(subscriptionUpdate: true)
        if !creator.isScanning {
            DispatchQueue.main.async { [weak self] in self?.finishUpdate(item, creator: creator, batch: batch, store: store) }
        }
    }

    func resultText(_ item: CreatorSubscription, batch: BatchStore) -> String {
        guard let ids = item.lastQueuedItemIDs, !ids.isEmpty else { return item.lastMessage }
        let idSet = Set(ids), jobs = batch.items.filter { idSet.contains($0.id) }
        let done = jobs.filter { $0.status == .completed }.count
        let failed = jobs.filter { $0.status == .failed || $0.status == .cancelled }.count
        let waiting = jobs.filter { $0.status == .pending || $0.status == .running }.count
        return "新增 \(item.lastAddedCount) · 完成 \(done) · 失败/取消 \(failed) · 待完成 \(waiting) · 已存在 \(item.lastExistingCount)"
            + (item.lastScanComplete ? "" : "。主页采集不完整，可再次更新。")
    }

    func cancel(creator: CreatorStore) {
        guard isUpdating else { return }
        cancelRequested = true; creator.cancel()
    }

    private func finishUpdate(_ item: CreatorSubscription, creator: CreatorStore, batch: BatchStore, store: Store) {
        guard updatingID == item.id, !creator.isScanning else { return }
        observation = nil
        defer { updatingID = nil }
        var next = subscriptions
        guard let i = next.firstIndex(where: { $0.id == item.id }) else { return }
        next[i].lastCheckedAt = Date(); next[i].lastAddedCount = 0; next[i].lastExistingCount = 0
        next[i].lastScanComplete = false; next[i].lastQueuedItemIDs = nil
        if cancelRequested || creator.scanCancelled {
            next[i].lastMessage = "已取消更新，没有新增下载任务。"
        } else if creator.platform != item.platform || creator.scannedCreatorID != item.creatorID || creator.homepageURL?.absoluteString != item.homepage || !creator.hasScanReceipt {
            next[i].lastMessage = "更新失败：" + (creator.error ?? "未收到对应博主的有效采集回执。")
        } else if !batch.canWriteLibrary || store.historyUnavailable || store.historyIssue != nil {
            next[i].lastMessage = "资料库读取异常，未新增下载任务。"
        } else {
            let known = Self.knownWorks(store: store, batch: batch)
            let videos = creator.posts.filter(\.isVideo)
            let fresh = CreatorSubscriptionCore.missing(videos, platform: item.platform, known: known)
            let existing = videos.filter { post in BatchLinkParser.identity(for: post.link, videoID: post.id).map { known.contains($0) } == true }.count
            // Persist the check before starting downloads; queue itself also saves before starting.
            next[i].name = creator.creatorName.isEmpty ? item.name : creator.creatorName
            next[i].lastExistingCount = existing; next[i].lastScanComplete = creator.scanComplete
            next[i].lastMessage = fresh.isEmpty ? "没有需要下载的新视频，已存在 \(existing) 个。" : "发现 \(fresh.count) 个新视频，已存在 \(existing) 个。"
            if !creator.scanComplete { next[i].lastMessage += "本次仅返回部分主页作品：" + String((creator.error ?? creator.detail).prefix(1500)) }
            guard commit(next) else { return }
            if !fresh.isEmpty {
                let previousIDs = Set(batch.items.map(\.id))
                let added = batch.enqueueCreatorPosts(fresh, sourceURL: item.homepage, singleBusy: store.busy,
                    startImmediately: true, subscriptionTarget: item.collectionID, subscriptionKnown: known,
                    subscriptionQuality: Quality(rawValue: item.quality), subscriptionAudio: item.includeAudio)
                next[i].lastAddedCount = added
                next[i].lastQueuedItemIDs = batch.items.filter { !previousIDs.contains($0.id) }.map(\.id)
                next[i].lastMessage = added > 0
                    ? "新增 \(added) 个视频已加入下载，已存在 \(existing) 个。" + (creator.scanComplete ? "" : "本次主页采集不完整，可再次更新补齐。")
                    : "新增下载入队失败：" + (batch.error ?? "没有成功保存队列。")
                _ = commit(next)
            }
            message = next[i].lastMessage
            return
        }
        if commit(next) { message = next[i].lastMessage }
    }
}
