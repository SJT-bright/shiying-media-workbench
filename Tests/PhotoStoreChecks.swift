import Foundation

enum Quality: String { case compact = "480", balanced = "720", original = "highest" }

@main struct PhotoStoreChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("shiying-photo-store-" + UUID().uuidString)
        defer {
            BatchStore.dataRootOverride = nil; BatchStore.workerOverrideURL = nil; BatchStore.toolsDirectoryOverride = nil
            try? fm.removeItem(at: root)
        }
        BatchStore.dataRootOverride = root
        BatchStore.workerOverrideURL = URL(fileURLWithPath: CommandLine.arguments[1])
        BatchStore.toolsDirectoryOverride = root.appendingPathComponent("no-audio-tools")
        var checks = 0
        func check(_ name: String, _ ok: Bool) { precondition(ok, "FAIL " + name); checks += 1; print("PASS " + name) }
        let store = BatchStore()
        store.newCollectionName = "离线图文队列"; _ = store.createCollection()
        store.includeAudio = true
        store.inputText = "https://www.douyin.com/note/7000000000000000002"
        store.enqueue()
        check("album link enters ordinary queue", store.items.count == 1 && store.items[0].wantsAudio)
        store.start()
        for _ in 0..<500 {
            if !store.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check("queue album completes without video audio conversion", !store.isRunning && store.items[0].status == .completed && store.items[0].isAlbum && store.items[0].audioError == nil && store.items[0].audioPath == nil)
        check("all ordered image paths persist", store.items[0].imagePaths?.map { URL(fileURLWithPath: $0).lastPathComponent } == ["001.png", "002.png"])
        check("albums do not count as missing audio", store.audioMissingCount == 0)
        store.exportMissingAudio()
        check("bulk audio export leaves album idle", !store.isRunning && !store.hasLiveChild)
        store.exportAudio(store.items[0].id)
        check("direct audio action explains album and stays idle", !store.isRunning && store.notice?.contains("图文") == true)
        store.play(store.items[0])
        check("album action opens internal viewer", store.viewingAlbum?.imagePaths == store.items[0].imagePaths)
        let restored = BatchStore()
        check("album survives native store restart", restored.items[0].isAlbum && restored.items[0].imagePaths == store.items[0].imagePaths && restored.completedCount == 1)
        store.shutdown()
        print("PhotoStoreChecks: \(checks) passed")
    }
}
