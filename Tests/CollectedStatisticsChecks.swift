import Foundation

enum Quality: String { case compact = "480", balanced = "720", original = "highest" }

@main struct CollectedStatisticsChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiying-collected-statistics-" + UUID().uuidString)
        BatchStore.dataRootOverride = root
        BatchStore.workerOverrideURL = URL(fileURLWithPath: CommandLine.arguments[1])
        defer {
            BatchStore.dataRootOverride = nil; BatchStore.workerOverrideURL = nil
            try? FileManager.default.removeItem(at: root)
        }
        let store = BatchStore()
        store.newCollectionName = "统计事务检查"; precondition(store.createCollection())
        store.includeAudio = false
        store.inputText = ["saved", "failed", "noCounts"].map { "https://weixin.qq.com/sph/" + $0 }.joined(separator: "\n")
        store.enqueue()
        var collected: [CreatorPost] = []
        store.onStatistics = { collected.append($0) }
        store.start()
        for _ in 0..<600 {
            if !store.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(!store.isRunning && store.completedCount == 2 && store.failedCount == 1)
        precondition(collected.count == 1 && collected[0].id == "synthetic-saved" && collected[0].link == "https://weixin.qq.com/sph/saved")
        precondition(collected[0].statistics?.commentCount == 0 && collected[0].statistics?.recommendCount == 12)
        precondition(store.items.first { $0.videoID == "synthetic-noCounts" }?.status == .completed)
        print("PASS saved batch counters match identity; failed download is not adopted; missing counters never reuse the previous job; true zero retained")
        store.shutdown()
    }
}
