import Foundation

// BatchStore uses only these production Quality values; no UI or App entry point in this host.
enum Quality: String { case compact = "480", balanced = "720", original = "highest" }

@main struct CollectionStoreChecks {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("shiying-folder-store-" + UUID().uuidString)
        defer { BatchStore.dataRootOverride = nil; try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ name: String, _ ok: Bool) { precondition(ok, "FAIL " + name); checks += 1; print("PASS " + name) }
        func fixture(_ name: String) -> BatchStore {
            BatchStore.dataRootOverride = root.appendingPathComponent(name)
            return BatchStore()
        }
        let store = fixture("normal")
        store.newCollectionName = "文案分析"
        check("create root with visible learning notes", store.createCollection(notes: "分析故事结构") && store.selectedCollection?.notes == "分析故事结构")
        let parent = store.selectedCollection!
        store.newCollectionName = "标题分析"
        check("create child inside real parent", store.createCollection(parentID: parent.id, notes: "比较标题句式") && store.selectedCollection?.parentID == parent.id)
        let child = store.selectedCollection!
        check("child directory exists in parent", child.path.hasPrefix(parent.path + "/") && fm.fileExists(atPath: child.path))
        check("edit notes persists", store.updateCollectionNotes(child.id, notes: "  对比开头钩子\n记录问题  ") && store.notesDraft == "对比开头钩子\n记录问题")
        let repo = BatchRepository(rootURL: root.appendingPathComponent("normal/batch"))
        check("restart preserves hierarchy and notes", try repo.load().collections.first { $0.id == child.id }?.notes == store.notesDraft)
        store.newCollectionName = "钩子分类"
        check("create separate destination", store.createCollection())
        let destination = store.selectedCollection!
        check("store adopts real move and relocation event", store.moveCollection(child.id, to: destination.id) && store.lastCollectionMove?.source == child.path && store.collections.first { $0.id == child.id }?.parentID == destination.id)
        store.isRunning = true
        let before = store.collections
        check("busy queue blocks physical move with clear reason", !store.moveCollection(child.id, to: nil) && store.collections == before && store.error?.contains("队列") == true)
        store.isRunning = false
        let invalid = fixture("invalid")
        invalid.newCollectionName = "../非法"
        check("invalid name preserves input and library", !invalid.createCollection() && invalid.collections.isEmpty && invalid.newCollectionName == "../非法")
        let notesFault = fixture("notes-fault")
        notesFault.newCollectionName = "保留原备注"; _ = notesFault.createCollection(notes: "原备注")
        let saved = notesFault.collections
        let badFile = root.appendingPathComponent("notes-fault/batch/batch-library.json")
        let bad = Data("{坏JSON".utf8); try bad.write(to: badFile)
        notesFault.notesDraft = "不能丢的草稿"
        check("failed note save restores original metadata and draft", !notesFault.updateCollectionNotes(saved[0].id, notes: notesFault.notesDraft) && notesFault.collections == saved && notesFault.notesDraft == "不能丢的草稿")
        check("corrupt disk library not overwritten", try Data(contentsOf: badFile) == bad)
        notesFault.selectCollection(saved[0].id)
        check("blocked library reports reason after navigation", !notesFault.updateCollectionNotes(saved[0].id, notes: "重试") && notesFault.error?.contains("不可写") == true)
        let createFault = fixture("create-fault")
        createFault.newCollectionName = "原文件夹"; _ = createFault.createCollection()
        let original = createFault.collections
        try bad.write(to: root.appendingPathComponent("create-fault/batch/batch-library.json"))
        createFault.newCollectionName = "待创建"
        check("failed create rolls back metadata and only empty new directory", !createFault.createCollection(notes: "草稿") && createFault.collections == original && !fm.fileExists(atPath: root.appendingPathComponent("create-fault/资料/待创建").path) && createFault.newCollectionName == "待创建")
        print("CollectionStoreChecks: \(checks) passed")
    }
}
