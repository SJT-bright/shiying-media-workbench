import Foundation
import Combine

enum Quality: String { case compact = "480", balanced = "720", original = "highest" }

@main struct BatchProgressChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("shiying-batch-progress-" + UUID().uuidString)
        defer {
            BatchStore.dataRootOverride = nil; BatchStore.workerOverrideURL = nil
            try? fm.removeItem(at: root)
        }
        BatchStore.workerOverrideURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        func check(_ name: String, _ ok: Bool) {
            precondition(ok, "FAIL " + name); checks += 1; print("PASS " + name)
        }
        func close(_ left: Double, _ right: Double) -> Bool { abs(left - right) < 0.000001 }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            check("queue event arrives before deadline", condition())
        }
        func makeStore(_ name: String) -> BatchStore {
            BatchStore.dataRootOverride = root.appendingPathComponent(name)
            let store = BatchStore(); store.newCollectionName = name; _ = store.createCollection()
            return store
        }
        func item(_ store: BatchStore, _ index: Int, status: BatchStatus = .pending) -> BatchItem {
            var value = BatchItem(collectionID: store.selectedCollection!.id,
                                  link: "https://www.douyin.com/video/\(7300000000000000000 + index)",
                                  sourceText: "synthetic progress")
            value.status = status; value.wantsAudio = false
            return value
        }
        func marker(_ store: BatchStore, _ value: BatchItem, _ suffix: String) -> URL {
            URL(fileURLWithPath: store.selectedCollection!.path)
                .appendingPathComponent(value.link.components(separatedBy: "/").last! + suffix)
        }
        func release(_ store: BatchStore, _ value: BatchItem) throws {
            try Data().write(to: marker(store, value, ".release"))
        }
        func ready(_ store: BatchStore, _ value: BatchItem) async throws {
            try await wait { fm.fileExists(atPath: marker(store, value, ".ready").path)
                && store.detail.hasSuffix("正在下载视频") }
        }

        // Reproduce the reported shape: 22 historical jobs followed by 15 new jobs.
        let store = makeStore("history22-new15")
        let old = (0..<22).map { item(store, $0, status: .completed) }
        let new = (22..<37).map { item(store, $0) }
        store.items = old + new
        try Data().write(to: marker(store, new[3], ".fail"))
        var details: [String] = [], fractions: [Double] = []
        let detailSink = store.$detail.sink { details.append($0) }
        let progressSink = store.$progress.sink { fractions.append($0) }
        store.start()
        check("first parse starts at 1/15 with historical items", store.detail.hasPrefix("本轮 1/15 · 正在解析"))
        for index in new.indices {
            try await ready(store, new[index])
            check("job \(index + 1) uses the current run ordinal", store.detail == "本轮 \(index + 1)/15 · 正在下载视频")
            check("job \(index + 1) progress uses the same denominator", close(store.progress, (Double(index) + 0.25) / 15))
            try release(store, new[index])
        }
        try await wait { !store.isRunning }
        check("failure counts once and does not stop later jobs", store.failedCount == 1 && store.completedCount == 36)
        check("old records remain byte-equivalent", Array(store.items.prefix(22)) == old)
        check("total library count remains 37", store.totalCount == 37)
        check("every parse stage retains the run number", (1...15).allSatisfy { n in details.contains { $0.hasPrefix("本轮 \(n)/15 · 正在解析") } })
        check("metadata stages retain the same run number", (1...15).allSatisfy { n in details.contains { $0.hasPrefix("本轮 \(n)/15 · 正在处理") } })
        check("each completion reaches its exact run fraction", (1...15).allSatisfy { n in fractions.contains { close($0, Double(n) / 15) } })
        check("progress never jumps backward between jobs", zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        check("end progress reaches one", store.progress == 1)
        detailSink.cancel(); progressSink.cancel()

        // A scoped subscription run excludes unrelated pending jobs. Pause/resume
        // starts a fresh run of the remaining scoped jobs, with a matching numerator.
        let scoped = makeStore("scoped-pause")
        let unrelated = (100..<103).map { item(scoped, $0) }
        let targets = (200..<202).map { item(scoped, $0) }
        scoped.items = [unrelated[0], targets[0], unrelated[1], targets[1], unrelated[2]]
        scoped.start(only: Set(targets.map(\.id)))
        try await ready(scoped, targets[0])
        check("scoped run counts two, excluding three unrelated jobs", scoped.detail == "本轮 1/2 · 正在下载视频" && close(scoped.progress, 0.125))
        scoped.pause(); try release(scoped, targets[0])
        try await wait { !scoped.isRunning }
        check("pause waits for current job and counts it once", scoped.isPaused && close(scoped.progress, 0.5))
        scoped.resume(); try await ready(scoped, targets[1])
        check("resumed remaining scope starts at 1/1", scoped.detail == "本轮 1/1 · 正在下载视频" && close(scoped.progress, 0.25))
        try release(scoped, targets[1]); try await wait { !scoped.isRunning }
        check("scope leaves all unrelated tasks pending", unrelated.allSatisfy { value in scoped.items.first { $0.id == value.id }?.status == .pending })

        // A new run, cancellation/retry, and an invalid collection must not reuse
        // a library offset or leak a counter from an earlier run.
        scoped.start(); try await ready(scoped, unrelated[0])
        check("new ordinary run starts at 1/3", scoped.detail == "本轮 1/3 · 正在下载视频")
        scoped.cancelCurrent(); try await wait { !scoped.isRunning }
        check("cancel stops current job and pauses", scoped.isPaused && scoped.cancelledCount == 1)
        scoped.retry(unrelated[0].id)
        try fm.removeItem(at: marker(scoped, unrelated[0], ".ready"))
        scoped.start(only: [unrelated[0].id]); try await ready(scoped, unrelated[0])
        check("retry scope starts at 1/1", scoped.detail == "本轮 1/1 · 正在下载视频")
        try release(scoped, unrelated[0]); try await wait { !scoped.isRunning }
        check("retry leaves other pending tasks intact", scoped.pendingCount == 2 && scoped.cancelledCount == 0)

        let missing = makeStore("missing-folder")
        var bad = item(missing, 300); bad.collectionID = UUID()
        let good = item(missing, 301); missing.items = [bad, good]
        missing.start(); try await ready(missing, good)
        check("missing collection advances the same run once", missing.detail == "本轮 2/2 · 正在下载视频" && close(missing.progress, 0.625))
        try release(missing, good); try await wait { !missing.isRunning }
        check("missing collection fails while valid item completes", missing.failedCount == 1 && missing.completedCount == 1)
        print("BatchProgressChecks: \(checks) passed")
    }
}
