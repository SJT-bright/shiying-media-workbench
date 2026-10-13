import Foundation
import AppKit
import Darwin

@main struct SingleCoverStoreChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("shiying-single-cover-" + UUID().uuidString)
        let defaults = UserDefaults.standard, suite = "com.local.shiying.testing", previous = defaults.persistentDomain(forName: suite)
        let clipboard = NSPasteboard.general
        let previousClipboard = clipboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            Store.dataRootOverride = nil; Store.workerOverrideURL = nil
            if let previous { defaults.setPersistentDomain(previous, forName: suite) } else { defaults.removePersistentDomain(forName: suite) }
            clipboard.clearContents()
            let items = previousClipboard.map { pairs -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, data) in pairs { item.setData(data, forType: type) }; return item }
            if !items.isEmpty { clipboard.writeObjects(items) }
            try? fm.removeItem(at: base)
        }
        Store.workerOverrideURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var count = 0
        func check(_ name: String, _ ok: Bool) { precondition(ok, "FAIL " + name); count += 1; print("PASS " + name) }
        func fixture(_ name: String, both: Bool = false) -> Store {
            Store.dataRootOverride = base.appendingPathComponent(name)
            let store = Store(); store.folder = base.appendingPathComponent(name + "/videos").path; store.revealOnComplete = false
            store.text = "https://www.douyin.com/video/7000000000000000007?case=" + name
            store.captureVideo = both; store.captureCover = true
            return store
        }
        func idle(_ store: Store) async throws {
            for _ in 0..<500 { if !store.busy { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            preconditionFailure("worker did not finish")
        }
        func events(_ name: String) -> String { (try? String(contentsOf: base.appendingPathComponent(name + "/worker-events.jsonl"), encoding: .utf8)) ?? "" }
        let normal = fixture("default"); normal.captureCover = false; normal.captureVideo = true; normal.download(); try await idle(normal)
        check("video-only retains immediate video save", normal.records.count == 1 && normal.result?.isAlbum == false && normal.photoDraft == nil)
        let copy = fixture("copy"); copy.preview(); try await idle(copy)
        let copyPaths = copy.photoPaths
        check("cover preview has original identity and writes no formal record", copy.photoDraft?.isCover == true && copy.photoDraft?.videoID == "7000000000000000007" && copy.records.isEmpty && (try? fm.contentsOfDirectory(atPath: copy.folder).isEmpty) == true)
        check("cover-only never calls video download", !events("copy").contains("download"))
        copy.copyPhoto(0); let bytes = clipboard.data(forType: .png); copy.cancelPhotoSave()
        check("copy survives deleting all temporary cover files", bytes != nil && clipboard.data(forType: .png) == bytes && copyPaths.allSatisfy { !fm.fileExists(atPath: $0) } && copy.records.isEmpty)
        let confirm = fixture("confirm"); confirm.download(); try await idle(confirm); let oldPaths = confirm.photoPaths
        confirm.confirmPhotoSave(); try await idle(confirm)
        let saved = confirm.result!
        check("confirm publishes one cover and removes temporary original", saved.isCover && saved.isAlbum && confirm.records.count == 1 && saved.imagePaths!.allSatisfy { fm.fileExists(atPath: $0) } && oldPaths.allSatisfy { !fm.fileExists(atPath: $0) })
        let restart = Store()
        check("restart reads cover role and keeps confirmed files", restart.completed.first?.isCover == true && saved.imagePaths!.allSatisfy { fm.fileExists(atPath: $0) })
        confirm.preview(); try await idle(confirm); confirm.cancelPhotoSave()
        check("cancelling later draft preserves earlier confirmed cover", confirm.records.count == 1 && saved.imagePaths!.allSatisfy { fm.fileExists(atPath: $0) })
        let both = fixture("both", both: true); both.download(); try await idle(both)
        check("both options wait for cover confirmation before video", both.photoDraft?.isCover == true && both.records.isEmpty && !events("both").contains("download") && both.confirmationTitle == "确认保存并下载视频")
        both.confirmPhotoSave(); try await idle(both)
        check("both saves cover then video as separate original assets", both.completed.count == 2 && both.completed.filter(\.isCover).count == 1 && both.result?.isCover == false && both.photoDraft == nil && events("both").contains("download"))
        let options = fixture("options"); options.preview(); try await idle(options); let optionPaths = options.photoPaths
        options.captureCover = false
        check("changing capture mode clears its pending images", options.photoDraft == nil && optionPaths.allSatisfy { !fm.fileExists(atPath: $0) })
        options.download(); check("empty selection starts no worker", !options.captureSelectionValid && !options.busy && options.records.isEmpty)
        let page = fixture("page"); page.preview(); try await idle(page); let pagePaths = page.photoPaths; page.page = "下载记录"
        check("leaving page cleans unconfirmed cover", pagePaths.allSatisfy { !fm.fileExists(atPath: $0) } && page.records.isEmpty)
        let bad = fixture("bad"); bad.preview(); try await idle(bad)
        let broken = Data("{坏JSON".utf8), history = base.appendingPathComponent("bad/history.json"); try broken.write(to: history)
        bad.confirmPhotoSave(); try await idle(bad)
        check("failed history write rolls back copies and preserves draft", bad.records.isEmpty && bad.photoDraft?.isCover == true && bad.photoPaths.allSatisfy { fm.fileExists(atPath: $0) } && (try? fm.contentsOfDirectory(atPath: bad.folder).isEmpty) == true && (try? Data(contentsOf: history)) == broken)
        bad.cancelPhotoSave()
        let replaced = fixture("replaced"); replaced.preview(); try await idle(replaced)
        let replacedPath = URL(fileURLWithPath: replaced.photoPaths[0])
        var replacedBytes = try Data(contentsOf: replacedPath); replacedBytes.append(0); try replacedBytes.write(to: replacedPath)
        replaced.confirmPhotoSave(); try await idle(replaced)
        check("external replacement of a pending cover cannot enter history", replaced.records.isEmpty && replaced.photoDraft?.isCover == true && replaced.error?.contains("变化") == true && (try? fm.contentsOfDirectory(atPath: replaced.folder).isEmpty) == true)
        replaced.cancelPhotoSave()
        let failed = fixture("fail"); failed.preview(); try await idle(failed)
        check("failed cover cleans partially downloaded images", failed.photoDraft == nil && failed.records.isEmpty && failed.error != nil && (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("fail/photo-previews").path).isEmpty) == true)
        let slow = fixture("slow"); slow.preview()
        for _ in 0..<100 { if slow.video != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        slow.cancel(); try await idle(slow)
        check("cancel during cover download waits then removes owned files", !slow.hasLiveChild && slow.photoDraft == nil && slow.records.isEmpty && (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("slow/photo-previews").path).isEmpty) == true)
        let locked = fixture("locked"); locked.otherTaskIsBusy = { true }; locked.download(); locked.preview()
        check("global task lock blocks second single worker", !locked.busy && locked.records.isEmpty && locked.photoDraft == nil)
        let legacy = Record(title: "旧视频", author: "", link: "", quality: .original, folder: "", status: "完成")
        check("legacy record keeps video semantics", !legacy.isAlbum && !legacy.isCover && (try? JSONDecoder().decode(Record.self, from: JSONEncoder().encode(legacy)))?.mediaKind == nil)
        print("SingleCoverStoreChecks: \(count) passed")
    }
}
