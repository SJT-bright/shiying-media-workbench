import Foundation

@main
struct PersistenceChecks {
    @MainActor static func main() throws {
        guard CommandLine.arguments.contains("--test-mode"),
              let root = shiyingTestDataRoot(fallback: ""), !root.path.isEmpty,
              root.path.contains("build/persistence-") else { fatalError("isolated test root required") }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("history.json")
        let repository = HistoryRepository<Record>(fileURL: history)
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            guard condition else { fatalError("FAIL \(name)") }
            checks += 1; print("PASS \(name)")
        }
        func record(_ title: String) -> Record {
            Record(title: title, author: "作者", link: "https://www.douyin.com/video/7689866306497170697",
                   quality: .original, folder: root.path, status: "完成")
        }

        check("missing history is empty", try repository.load().isEmpty)
        check("reading missing history creates no file", !fm.fileExists(atPath: history.path))
        let first = record("旧记录")
        try repository.save([first])
        let firstBytes = try Data(contentsOf: history)
        let second = record("新记录")
        try repository.save([second, first])
        check("legacy array and UUID/date decode", try repository.load().map(\.id) == [second.id, first.id])
        check("last readable bytes backed up", try Data(contentsOf: repository.backupURL) == firstBytes)

        let damaged = Data("{ damaged history".utf8)
        try damaged.write(to: history)
        let brokenStore = Store()
        check("bad history has persistent warning", brokenStore.historyUnavailable && brokenStore.historyIssue != nil)
        brokenStore.records.append(record("本次内存记录"))
        check("bad startup history blocks writing", !brokenStore.save())
        check("bad history original bytes retained", try Data(contentsOf: history) == damaged)
        check("good backup not overwritten by damage", try Data(contentsOf: repository.backupURL) == firstBytes)
        brokenStore.remove(brokenStore.records[0])
        check("blocked remove keeps session record", brokenStore.records.count == 1)

        try firstBytes.write(to: history)
        let loadedStore = Store()
        check("valid history loads", loadedStore.records.first?.id == first.id && loadedStore.historyIssue == nil)
        try damaged.write(to: history)
        loadedStore.records.insert(second, at: 0)
        check("runtime damage blocks save", !loadedStore.save() && loadedStore.historyIssue != nil)
        check("runtime damaged bytes retained", try Data(contentsOf: history) == damaged)
        check("new session records retained in memory", loadedStore.records.map(\.id) == [second.id, first.id])

        try firstBytes.write(to: history)
        try fm.removeItem(at: repository.backupURL)
        try fm.createDirectory(at: repository.backupURL, withIntermediateDirectories: false)
        let writeFailureStore = Store()
        writeFailureStore.records.insert(second, at: 0)
        check("backup write failure visible", !writeFailureStore.save() && writeFailureStore.historyIssue != nil)
        check("write failure keeps existing history bytes", try Data(contentsOf: history) == firstBytes)
        try fm.removeItem(at: repository.backupURL)

        let batchRoot = root.appendingPathComponent("queue")
        BatchStore.dataRootOverride = batchRoot
        let batch = BatchStore()
        batch.newCollectionName = "测试主题"
        batch.createCollection()
        check("isolated collection created", batch.selectedCollection != nil)
        batch.inputText = "旧原文 https://www.douyin.com/video/7689866306497170697"
        batch.enqueue()
        check("successful enqueue commits once and clears input", batch.items.count == 1 && batch.imports.count == 1 && batch.inputText.isEmpty)
        let library = batchRoot.appendingPathComponent("batch/batch-library.json")
        let oldIDs = batch.items.map(\.id), oldImports = batch.imports.map(\.id)
        try damaged.write(to: library)
        let newInput = "保留这段原文 https://www.douyin.com/video/7689105887553670410"
        batch.inputText = newInput
        batch.enqueue()
        check("failed enqueue preserves exact original text", batch.inputText == newInput)
        check("failed enqueue rolls back items and imports", batch.items.map(\.id) == oldIDs && batch.imports.map(\.id) == oldImports)
        check("failed enqueue gives no success notice", batch.notice == nil && batch.error != nil)
        check("failed enqueue leaves library bytes unchanged", try Data(contentsOf: library) == damaged)
        batch.shutdown()
        print("PersistenceChecks: \(checks) passed / ALL_OK")
    }
}
