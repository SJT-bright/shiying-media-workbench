import Foundation
import Darwin

@main struct SinglePhotoStoreChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("shiying-single-photo-" + UUID().uuidString)
        let defaults = UserDefaults.standard, suite = "com.local.shiying.testing", previous = defaults.persistentDomain(forName: suite)
        defer {
            Store.dataRootOverride = nil; Store.workerOverrideURL = nil
            if let previous { defaults.setPersistentDomain(previous, forName: suite) } else { defaults.removePersistentDomain(forName: suite) }
            try? fm.removeItem(at: base)
        }
        Store.workerOverrideURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var count = 0
        func check(_ name: String, _ ok: Bool) { precondition(ok, "FAIL " + name); count += 1; print("PASS " + name) }
        func fixture(_ name: String) -> Store {
            Store.dataRootOverride = base.appendingPathComponent(name)
            let store = Store(); store.folder = base.appendingPathComponent(name + "/videos").path; store.revealOnComplete = false
            store.text = "https://v.douyin.com/album/"; return store
        }
        func idle(_ store: Store) async throws {
            for _ in 0..<500 { if !store.busy { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            preconditionFailure("worker did not finish")
        }
        let store = fixture("confirm")
        store.preview(); try await idle(store)
        check("parse automatically downloads album but writes no history", store.photoDraft?.imagePaths?.count == 2 && store.records.isEmpty && store.result == nil && !fm.fileExists(atPath: base.appendingPathComponent("confirm/history.json").path))
        check("temporary preview leaves selected save directory empty", try fm.contentsOfDirectory(atPath: store.folder).isEmpty)
        let temporary = store.photoDraft!.imagePaths!
        store.confirmPhotoSave(); try await idle(store)
        check("confirmation writes one completed album and original paths survive", store.records.count == 1 && store.result?.isAlbum == true && store.result?.status == "完成" && store.result!.imagePaths!.allSatisfy { fm.fileExists(atPath: $0) })
        check("confirmation removes all temporary image files", temporary.allSatisfy { !fm.fileExists(atPath: $0) } && (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("confirm/photo-previews").path).isEmpty) == true)
        let saved = store.result!, restarted = Store()
        check("restart reads confirmed album and retains its bytes", restarted.records.first?.id == saved.id && saved.imagePaths!.allSatisfy { fm.fileExists(atPath: $0) })
        store.preview(); try await idle(store); store.cancelPhotoSave()
        check("cancelling later preview never removes earlier confirmed album", store.records.count == 1 && saved.imagePaths!.allSatisfy { fm.fileExists(atPath: $0) } && store.photoDraft == nil)
        let changed = fixture("changed"); changed.preview(); try await idle(changed)
        let changedPaths = changed.photoPaths; changed.text = "https://v.douyin.com/another/"; changed.inputChanged()
        check("changing input disposes only current preview", changed.photoDraft == nil && changedPaths.allSatisfy { !fm.fileExists(atPath: $0) } && changed.records.isEmpty)
        let page = fixture("page"); page.preview(); try await idle(page); let pagePaths = page.photoPaths; page.page = "下载记录"
        check("leaving new-download page clears preview without history", pagePaths.allSatisfy { !fm.fileExists(atPath: $0) } && page.records.isEmpty)
        let quit = fixture("quit"); quit.preview(); try await idle(quit); let quitPaths = quit.photoPaths; quit.shutdown()
        check("quit deletes unconfirmed images", quitPaths.allSatisfy { !fm.fileExists(atPath: $0) })
        let window = fixture("window"); window.preview(); try await idle(window); let windowPaths = window.photoPaths; window.discardPhotoPreviewForClosedWindow()
        check("closing window clears its unconfirmed images", windowPaths.allSatisfy { !fm.fileExists(atPath: $0) })
        let direct = fixture("direct"); direct.download(); try await idle(direct)
        check("direct start for unknown album also waits for confirmation", direct.photoDraft != nil && direct.records.isEmpty && (try? fm.contentsOfDirectory(atPath: direct.folder).isEmpty) == true); direct.cancelPhotoSave()
        let failed = fixture("failed"); failed.text = "https://v.douyin.com/fail/"; failed.preview(); try await idle(failed)
        check("failed album writes no history and cleans partial images", failed.error?.contains("失败") == true && failed.records.isEmpty && (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("failed/photo-previews").path).isEmpty) == true)
        let bad = fixture("bad"); bad.preview(); try await idle(bad)
        let broken = Data("{坏JSON".utf8), history = base.appendingPathComponent("bad/history.json"); try broken.write(to: history)
        bad.confirmPhotoSave(); try await idle(bad)
        check("history failure rolls back new formal files and keeps pending originals", bad.records.isEmpty && bad.photoDraft != nil && bad.photoPaths.allSatisfy { fm.fileExists(atPath: $0) } && (try? fm.contentsOfDirectory(atPath: bad.folder).isEmpty) == true && (try? Data(contentsOf: history)) == broken)
        bad.cancelPhotoSave()
        let slow = fixture("slow"); slow.text = "https://v.douyin.com/slow/"; slow.preview()
        for _ in 0..<100 { if slow.video != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        slow.cancel(); try await idle(slow)
        check("cancel during auto-download releases worker and temporary directory", !slow.hasLiveChild && slow.photoDraft == nil && slow.records.isEmpty && (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("slow/photo-previews").path).isEmpty) == true)
        let video = fixture("video"); video.text = "https://v.douyin.com/video/"; video.download(); try await idle(video)
        check("video direct download retains automatic permanent save behavior", video.result?.isAlbum == false && video.result?.status == "完成" && video.records.count == 1 && video.photoDraft == nil)
        print("SinglePhotoStoreChecks: \(count) passed")
    }
}
