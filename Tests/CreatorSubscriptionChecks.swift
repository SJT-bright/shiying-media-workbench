import Foundation

@main struct CreatorSubscriptionChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = shiyingTestDataRoot(fallback: "/tmp/shiying-subscription-test")!
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = 0
        func check(_ name: String, _ ok: Bool) { precondition(ok, "FAIL " + name); checks += 1; print("PASS " + name) }
        func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
        let home = "https://www.douyin.com/user/SUB_CREATOR"
        let path = root.appendingPathComponent("repo/creator-subscriptions.json")
        let repo = CreatorSubscriptionRepository(fileURL: path)
        check("new database reads empty without writing", try repo.load().subscriptions.isEmpty && !fm.fileExists(atPath: path.path))
        let directory = root.appendingPathComponent("shared/真实中文目录")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let collection = StudyCollection(name: "目录", path: directory.path)
        let sub = CreatorSubscription(platform: .douyin, creatorID: "SUB_CREATOR", homepage: home, name: "同名博主", collectionID: collection.id, quality: "highest", includeAudio: false)
        try repo.save(CreatorSubscriptionLibrary(subscriptions: [sub]))
        check("restart preserves homepage and identity", try CreatorSubscriptionRepository(fileURL: path).load().subscriptions == [sub])
        let bili = CreatorSubscription(platform: .bilibili, creatorID: "12345", homepage: "https://space.bilibili.com/12345", name: "同名博主", collectionID: collection.id, quality: "720", includeAudio: false)
        try repo.save(CreatorSubscriptionLibrary(subscriptions: [sub,bili]))
        check("same display name is independent by platform", try repo.load().subscriptions.count == 2)
        check("same author cannot be stored twice", rejects { try repo.save(CreatorSubscriptionLibrary(subscriptions: [sub,sub])) })
        check("share URL cannot masquerade as homepage", rejects { _ = try CreatorSubscriptionCore.homepage(platform: .douyin, creatorID: "SUB_CREATOR", url: "https://v.douyin.com/share") })
        check("homepage identity mismatch rejected", rejects { _ = try CreatorSubscriptionCore.homepage(platform: .bilibili, creatorID: "123", url: "https://space.bilibili.com/456") })
        check("credentials in homepage rejected", rejects { _ = try CreatorSubscriptionCore.homepage(platform: .douyin, creatorID: "SUB_CREATOR", url: "https://user:secret@www.douyin.com/user/SUB_CREATOR") })
        check("wechat single share cannot become author subscription", rejects { _ = try CreatorSubscriptionCore.homepage(platform: .wechat, creatorID: "one", url: "https://weixin.qq.com/sph/one") })
        let rival = CreatorSubscriptionRepository(fileURL: path); _ = try rival.load()
        try repo.save(CreatorSubscriptionLibrary(subscriptions: [sub]))
        check("concurrent writer cannot overwrite newer database", rejects { try rival.save(CreatorSubscriptionLibrary(subscriptions: [bili])) })
        let bad = Data("{broken".utf8); try bad.write(to: path)
        check("corruption after load is preserved", rejects { try repo.save(CreatorSubscriptionLibrary()) } && (try? Data(contentsOf: path)) == bad)
        check("corrupt database not interpreted as empty", rejects { _ = try CreatorSubscriptionRepository(fileURL: path).load() })
        let blocked = CreatorSubscriptionStore(fileURL: path)
        check("corrupt database blocks mutations", !blocked.canWrite && blocked.issue != nil)
        let fixture = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Tests/fixtures/subscription_worker.py")
        CreatorStore.workerOverrideURL = fixture; CreatorStore.sessionFileOverride = root.appendingPathComponent("session.json")
        Store.dataRootOverride = root; BatchStore.dataRootOverride = root; BatchStore.workerOverrideURL = fixture
        defer { CreatorStore.workerOverrideURL = nil; Store.dataRootOverride = nil; BatchStore.dataRootOverride = nil }
        let store = Store(), batch = BatchStore(), creator = CreatorStore()
        let subscriptions = CreatorSubscriptionStore(fileURL: root.appendingPathComponent("creator-subscriptions.json"))
        store.folder = directory.path
        check("shared picker adopts existing directory", batch.useDestination(directory.path) && batch.selectedCollection?.path == store.folder)
        let target = batch.selectedCollection!
        check("repeat directory selection reuses folder UUID", batch.useDestination(directory.path) && batch.collections.count == 1 && batch.selectedCollection?.id == target.id)
        check("invalid directory is not registered", !batch.useDestination(root.appendingPathComponent("absent").path) && batch.collections.count == 1)
        creator.handle(["event":"creator", "id":"SUB_CREATOR", "nickname":"测试博主", "homepage":home], token: creator.scanGeneration)
        batch.includeAudio = false
        subscriptions.subscribe(creator: creator, batch: batch, store: store)
        check("scanned author can be subscribed", subscriptions.subscriptions.count == 1 && subscriptions.subscriptions[0].homepage == home)
        subscriptions.subscribe(creator: creator, batch: batch, store: store)
        check("repeated subscription updates settings without duplication", subscriptions.subscriptions.count == 1)
        creator.selectPlatform(.bilibili)
        creator.handle(["event":"creator", "id":"legacy-page-hash", "nickname":"测试UP主", "homepage":"https://space.bilibili.com/12345", "platform":"bilibili"], token:creator.scanGeneration)
        check("Bilibili visible-page receipt resolves stable official UID", creator.scannedCreatorID == "12345")
        subscriptions.subscribe(creator: creator, batch: batch, store: store)
        check("platform lists are independent", subscriptions.items(for:.douyin).count == 1 && subscriptions.items(for:.bilibili).count == 1 && subscriptions.items(for:.wechat).isEmpty)
        check("subscription state survives application restart", CreatorSubscriptionStore(fileURL: root.appendingPathComponent("creator-subscriptions.json")).subscriptions.count == 2)
        let existingFile = directory.appendingPathComponent("已保存.mp4"); try Data("saved".utf8).write(to: existingFile)
        store.records = [Record(title:"old",author:"old",link:"https://www.douyin.com/video/7000000000000000001",quality:.original,folder:directory.path,path:existingFile.path,status:"完成",error:nil)]
        var old = BatchItem(collectionID: UUID(), link:"https://www.douyin.com/video/7000000000000000002", sourceText:"another folder")
        old.status = .pending; batch.items = [old]
        let douyin = subscriptions.items(for:.douyin)[0]
        func wait() async throws {
            let deadline=Date().addingTimeInterval(12)
            while (subscriptions.isUpdating || batch.isRunning || creator.isScanning) && Date() < deadline { try await Task.sleep(nanoseconds:20_000_000) }
            check("update settles before deadline", !subscriptions.isUpdating && !batch.isRunning && !creator.isScanning)
        }
        subscriptions.update(douyin,creator:creator,batch:batch,store:store); try await wait()
        check("only missing works added across single and batch libraries", batch.items.count == 2 && subscriptions.items(for:.douyin)[0].lastAddedCount == 1)
        check("subscription update leaves unrelated pending queue untouched", batch.items.first?.id == old.id && batch.items.first?.status == .pending)
        check("update starts new video download automatically", batch.items.contains { $0.videoID == "7000000000000000003" && $0.status == .completed && $0.path.map { fm.fileExists(atPath:$0) } == true })
        check("download retains subscription directory and quality", batch.items.last?.collectionID == target.id && batch.items.last?.qualityRaw == "highest" && batch.items.last?.wantsAudio == false)
        let count = batch.items.count
        subscriptions.update(douyin,creator:creator,batch:batch,store:store); try await wait()
        check("second update adds zero duplicate tasks", batch.items.count == count && subscriptions.items(for:.douyin)[0].lastAddedCount == 0)
        let freshIndex=batch.items.firstIndex { $0.videoID == "7000000000000000003" }!
        try fm.removeItem(atPath:batch.items[freshIndex].path!)
        subscriptions.update(douyin,creator:creator,batch:batch,store:store); try await wait()
        check("missing on-disk video is recovered", subscriptions.items(for:.douyin)[0].lastAddedCount == 1 && batch.items.count == count + 1)
        // Failed/cancelled jobs and cover-only records cannot suppress a missing video.
        var failed=BatchItem(collectionID: target.id,link:"https://www.douyin.com/video/7000000000000000004",sourceText:"failed")
        failed.status = .failed; batch.items.append(failed)
        var cover=store.records[0]; cover.link=failed.link; cover.mediaKind="video_cover";store.records.append(cover)
        check("failed jobs and cover-only records do not count as saved videos", !CreatorSubscriptionStore.knownWorks(store:store,batch:batch).contains("douyin:7000000000000000004"))
        let scenario=root.appendingPathComponent("scenario.json")
        try Data("{\"wrong\":true}".utf8).write(to: scenario)
        let prior=batch.items.count
        subscriptions.update(douyin,creator:creator,batch:batch,store:store);try await wait()
        check("wrong author receipt cannot start downloads", batch.items.count == prior && subscriptions.items(for:.douyin)[0].lastMessage.contains("失败"))
        try Data("{\"slow\":true}".utf8).write(to: scenario)
        subscriptions.update(douyin,creator:creator,batch:batch,store:store);subscriptions.cancel(creator:creator);try await wait()
        check("cancelled update adds no tasks", batch.items.count == prior && subscriptions.items(for:.douyin)[0].lastMessage.contains("取消"))
        try Data("{\"partial\":true}".utf8).write(to: scenario)
        subscriptions.update(douyin,creator:creator,batch:batch,store:store);try await wait()
        check("partial scan remains explicitly incomplete", !subscriptions.items(for:.douyin)[0].lastScanComplete && subscriptions.items(for:.douyin)[0].lastMessage.contains("部分"))
        try Data("{}".utf8).write(to: scenario)
        let biliSub=subscriptions.items(for:.bilibili)[0]
        subscriptions.update(biliSub,creator:creator,batch:batch,store:store);try await wait()
        check("Bilibili subscription downloads its own new works", subscriptions.items(for:.bilibili)[0].lastAddedCount == 3 && batch.items.filter { $0.platformRaw == "bilibili" && $0.status == .completed }.count == 3)
        try Data("{\"downloadFail\":true}".utf8).write(to: scenario)
        let biliVideos=batch.items.filter { $0.platformRaw == "bilibili" && $0.status == .completed }
        for item in biliVideos { try fm.removeItem(atPath:item.path!) }
        subscriptions.update(biliSub,creator:creator,batch:batch,store:store);try await wait()
        check("failed downloads are visible in subscription result", subscriptions.resultText(subscriptions.items(for:.bilibili)[0],batch:batch).contains("失败/取消 3"))
        try Data("{}".utf8).write(to:scenario)
        subscriptions.update(biliSub,creator:creator,batch:batch,store:store);try await wait()
        check("later update retries failed or missing videos", subscriptions.items(for:.bilibili)[0].lastAddedCount == 3 && batch.items.filter { $0.platformRaw == "bilibili" && $0.status == .completed && $0.path.map { fm.fileExists(atPath:$0) } == true }.count == 3)
        let beforeRemove=batch.items.count
        subscriptions.remove(douyin.id)
        check("unsubscribe leaves saved files and queue intact", subscriptions.items(for:.douyin).isEmpty && batch.items.count == beforeRemove)
        batch.shutdown();creator.shutdown()
        print("CreatorSubscriptionChecks: \(checks) passed")
    }
}
