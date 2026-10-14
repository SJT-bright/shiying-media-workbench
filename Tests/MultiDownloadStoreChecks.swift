import Foundation
import AppKit
import Darwin

@main struct MultiDownloadStoreChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("shiying-multi-" + UUID().uuidString)
        let standard = UserDefaults.standard, suite = "com.local.shiying.testing", previous = standard.persistentDomain(forName: suite)
        let clipboard = NSPasteboard.general
        let previousClipboard = clipboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            Store.dataRootOverride = nil; Store.workerOverrideURL = nil
            if let previous { standard.setPersistentDomain(previous, forName: suite) } else { standard.removePersistentDomain(forName: suite) }
            clipboard.clearContents()
            let items = previousClipboard.map { pairs -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, data) in pairs { item.setData(data, forType: type) }; return item }
            if !items.isEmpty { clipboard.writeObjects(items) }
            try? fm.removeItem(at: base)
        }
        Store.workerOverrideURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var count = 0
        func check(_ name: String, _ ok: Bool) { precondition(ok, "FAIL " + name); count += 1; print("PASS " + name) }
        func link(_ name: String) -> String { "https://weixin.qq.com/sph/" + name }
        func fixture(_ name: String, input: [String], video: Bool = true, cover: Bool = false) -> Store {
            Store.dataRootOverride = base.appendingPathComponent(name)
            let store = Store(); store.folder = base.appendingPathComponent(name + "/videos").path; store.revealOnComplete = false
            store.captureVideo = video; store.captureCover = cover
            store.text = input.map(link).joined(separator: "\n")
            return store
        }
        func idle(_ store: Store) async throws {
            for _ in 0..<1000 { if !store.busy { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            preconditionFailure("multi worker did not finish")
        }
        func events(_ name: String) -> [[String: Any]] {
            let value = (try? String(contentsOf: base.appendingPathComponent(name + "/worker-events.jsonl"), encoding: .utf8)) ?? ""
            return value.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        let ten = fixture("ten", input: ["a", "b", "b", "c", "d", "e", "f", "g", "h", "i"])
        var collected: [CreatorPost] = []
        ten.onStatistics = { collected.append($0) }
        ten.preview(); check("busy spans complete list immediately", ten.busy && ten.isMultiLinkMode); try await idle(ten)
        check("ten pasted links become nine ordered distinct rows", ten.linkItems.map(\.link) == ["a", "b", "c", "d", "e", "f", "g", "h", "i"].map(link))
        check("positions and dedupe message reflect input", ten.linkItems.map(\.position) == Array(1...9) && ten.linkSummary.contains("10 条") && ten.linkSummary.contains("1 条重复"))
        check("every video has independent parsed metadata", ten.linkItems.allSatisfy { $0.video != nil && $0.status == "可下载" } && Set(ten.linkItems.compactMap { $0.video?.id }).count == 9 && ten.video == nil)
        check("parse does not save any videos or history", ten.records.isEmpty && events("ten").count == 9 && events("ten").allSatisfy { $0["command"] as? String == "info" })
        check("preview statistics wait for successful save", collected.isEmpty && ten.linkItems.allSatisfy { $0.video?.statistics?.recommendCount == 12 })
        ten.download(); try await idle(ten)
        check("all nine videos save without historical snapshot loss", ten.completed.count == 9 && ten.linkItems.allSatisfy(\.isCompleted))
        check("download files retain unique rows and original order", Set(ten.completed.compactMap(\.path)).count == 9 && events("ten").filter { $0["command"] as? String == "download" }.compactMap { $0["link"] as? String } == ten.linkItems.map(\.link))
        check("saved history contains all rows", try HistoryRepository<Record>(fileURL: base.appendingPathComponent("ten/history.json")).load().count == 9)
        check("every saved row forwards its own identity and statistics", collected.count == 9 && Set(collected.map(\.link)) == Set(ten.linkItems.map(\.link)) && collected.allSatisfy { $0.statistics?.likeCount == 9 })
        let originalEventCount = events("ten").count
        ten.download(); try await idle(ten)
        check("second unified start does not download saved rows again", events("ten").count == originalEventCount && ten.completed.count == 9)
        let movedFolder = base.appendingPathComponent("ten/moved-videos").path
        try fm.moveItem(atPath: ten.folder, toPath: movedFolder)
        ten.applyCollectionRelocation(CollectionRelocation(source: ten.folder, destination: movedFolder))
        check("completed rows follow actual collection relocation", ten.linkItems.allSatisfy { $0.result?.path?.hasPrefix(movedFolder + "/") == true && $0.completedResults.allSatisfy { fm.fileExists(atPath: $0.path!) } && $0.child.folder == movedFolder } && ten.completed.allSatisfy { fm.fileExists(atPath: $0.path!) })

        let fail = fixture("failure", input: ["one", "fail", "three"]); fail.download(); try await idle(fail)
        check("one failed URL does not stop later rows", fail.linkItems[0].isCompleted && fail.linkItems[1].error != nil && fail.linkItems[2].isCompleted && fail.completed.count == 2)
        let row = fixture("row", input: ["one", "two"]); row.preview(); try await idle(row)
        row.confirmLinkItem(row.linkItems[1].id); try await idle(row)
        check("per-row download saves only selected row", row.completed.count == 1 && !row.linkItems[0].isCompleted && row.linkItems[1].isCompleted)

        let covers = fixture("covers", input: ["one", "two", "three"], video: false, cover: true)
        covers.preview(); try await idle(covers)
        let coverPaths = covers.linkItems.flatMap(\.photoPaths)
        check("later child initialization preserves earlier owned drafts", covers.linkItems.allSatisfy { $0.photoDraft?.isCover == true } && coverPaths.count == 3 && coverPaths.allSatisfy { fm.fileExists(atPath: $0) })
        check("cover-only list requests no video downloads", covers.records.isEmpty && !events("covers").contains { $0["command"] as? String == "download" })
        covers.linkItems[0].copyPhoto(0); let bytes = clipboard.data(forType: .png)
        covers.linkItems[1].play(covers.linkItems[1].photoDraft!)
        check("row album viewer opens the matching temporary draft", covers.viewingAlbum?.id == covers.linkItems[1].photoDraft?.id)
        covers.confirmLinkItem(covers.linkItems[1].id); try await idle(covers)
        check("confirming a row closes its viewer before temporary originals are deleted", covers.viewingAlbum == nil)
        check("per-cover confirmation keeps other drafts intact", covers.completed.count == 1 && covers.linkItems[1].isCompleted && covers.linkItems[0].photoDraft != nil && covers.linkItems[2].photoDraft != nil && covers.linkItems[0].photoPaths.allSatisfy { fm.fileExists(atPath: $0) })
        let savedCover = covers.completed[0]
        covers.discardAllLinkItems()
        check("discarding all rows preserves saved cover and clipboard bytes", covers.linkItems.isEmpty && coverPaths.allSatisfy { !fm.fileExists(atPath: $0) } && savedCover.imagePaths!.allSatisfy { fm.fileExists(atPath: $0) } && bytes != nil && clipboard.data(forType: .png) == bytes)
        let both = fixture("both", input: ["one", "two"], cover: true); both.download(); try await idle(both)
        check("both capture options wait for every cover before downloads", both.linkItems.allSatisfy(\.canConfirm) && both.records.isEmpty && !events("both").contains { $0["command"] as? String == "download" })
        both.confirmAllLinkItems(); try await idle(both)
        check("both preserves separate covers and videos for every row", both.completed.count == 4 && both.completed.filter(\.isCover).count == 2 && both.linkItems.allSatisfy { $0.completedResults.count == 2 && $0.isCompleted })
        check("saved cover paths remain available after paired video completes", both.linkItems.allSatisfy { $0.photoPaths.count == 1 && $0.photoPaths.allSatisfy { fm.fileExists(atPath: $0) } })
        both.linkItems[0].copyPhoto(0)
        check("saved cover can still be copied after paired video completes", clipboard.data(forType: .png) != nil && both.linkItems[0].error == nil)
        let repreview = fixture("repreview", input: ["one", "two"], video: false, cover: true)
        repreview.preview(); try await idle(repreview)
        repreview.cancelLinkItem(repreview.linkItems[0].id)
        repreview.preview(); try await idle(repreview)
        check("preview restores cancelled draft while preserving other pending row", repreview.linkItems.allSatisfy { $0.photoDraft != nil && $0.photoPaths.allSatisfy { fm.fileExists(atPath: $0) } } && events("repreview").count == 3)
        repreview.discardAllLinkItems()
        let albums = fixture("albums", input: ["albumOne", "albumTwo"]); albums.download(); try await idle(albums)
        let albumPaths = albums.linkItems.flatMap(\.photoPaths)
        check("multiple albums have independent previews and require confirmation", albums.records.isEmpty && albums.linkItems.allSatisfy { $0.photoPaths.count == 2 && $0.photoDraft?.isAlbum == true })
        albums.confirmAllLinkItems(); try await idle(albums)
        check("confirming all albums persists all records and releases previews", albums.completed.count == 2 && albumPaths.allSatisfy { !fm.fileExists(atPath: $0) } && albums.completed.flatMap { $0.imagePaths ?? [] }.allSatisfy { fm.fileExists(atPath: $0) })

        let input = fixture("input", input: ["one", "two"], video: false, cover: true); input.preview(); try await idle(input)
        let oldPaths = input.linkItems.flatMap(\.photoPaths); input.text = link("replacement"); input.inputChanged()
        check("changing input clears every owned unconfirmed directory", input.linkItems.isEmpty && oldPaths.allSatisfy { !fm.fileExists(atPath: $0) })
        let page = fixture("page", input: ["one", "two"], video: false, cover: true); page.preview(); try await idle(page)
        let pagePaths = page.linkItems.flatMap(\.photoPaths); page.page = "下载记录"
        check("leaving page clears all pending drafts", page.linkItems.isEmpty && pagePaths.allSatisfy { !fm.fileExists(atPath: $0) })
        let close = fixture("close", input: ["one", "two"], video: false, cover: true); close.preview(); try await idle(close)
        let closePaths = close.linkItems.flatMap(\.photoPaths); close.discardPhotoPreviewForClosedWindow()
        check("closing window clears all pending drafts", close.linkItems.isEmpty && closePaths.allSatisfy { !fm.fileExists(atPath: $0) })
        let slow = fixture("slow", input: ["slow", "later"]); slow.download()
        for _ in 0..<150 { if slow.linkItems.first?.video != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        check("active child makes parent remain busy", slow.busy && slow.hasLiveChild)
        slow.cancel(); try await idle(slow)
        check("parent cancellation stops active child and unstarted rows", !slow.hasLiveChild && slow.records.isEmpty && !events("slow").contains { $0["link"] as? String == link("later") })
        let queued = fixture("queued", input: ["slow", "skip", "later"]); queued.preview()
        for _ in 0..<150 { if queued.linkItems.first?.video != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        queued.cancelLinkItem(queued.linkItems[1].id); queued.cancelLinkItem(queued.linkItems[0].id); try await idle(queued)
        check("cancelling queued row skips it while current-row cancellation continues later rows", queued.linkItems[1].status == "已取消" && queued.linkItems[2].video != nil && !events("queued").contains { $0["link"] as? String == link("skip") })
        queued.retryLinkItem(queued.linkItems[1].id); try await idle(queued)
        check("explicit row retry restores a skipped row", queued.linkItems[1].isCompleted && queued.completed.count == 1)
        let pending = fixture("pending", input: ["one", "slow", "later"], video: false, cover: true); pending.preview()
        for _ in 0..<200 { if pending.linkItems[0].photoDraft != nil && pending.linkItems[1].video != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        let pendingPaths = pending.linkItems.flatMap(\.photoPaths); pending.cancel(); try await idle(pending)
        check("cancelling whole list clears drafts made before active row", !pendingPaths.isEmpty && pendingPaths.allSatisfy { !fm.fileExists(atPath: $0) } && pending.linkItems.allSatisfy { $0.photoDraft == nil } && pending.records.isEmpty)
        let resume = fixture("resume", input: ["slowdownload", "other"], cover: true); resume.preview(); try await idle(resume)
        resume.confirmLinkItem(resume.linkItems[0].id)
        for _ in 0..<200 { if resume.linkItems[0].child.downloading && resume.completed.contains(where: \.isCover) { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        check("parent uses aggregate progress without remapping", resume.overall == resume.fraction)
        resume.cancelLinkItem(resume.linkItems[0].id); try await idle(resume)
        check("confirmed cover alone cannot mark cancelled dual-capture row complete", resume.completed.filter(\.isCover).count == 1 && !resume.linkItems[0].isCompleted && resume.linkItems[0].video != nil)
        resume.retryLinkItem(resume.linkItems[0].id); try await idle(resume)
        check("retry after video cancellation preserves one cover and downloads only missing video", resume.linkItems[0].isCompleted && resume.completed.filter(\.isCover).count == 1 && resume.completed.filter { !$0.isAlbum }.count == 1 && events("resume").filter { $0["cover"] as? Bool == true && $0["link"] as? String == link("slowdownload") }.count == 1)
        let exit = fixture("exit", input: ["slow", "later"]); exit.preview(); var shutdownFinished = false
        exit.shutdown { shutdownFinished = true }; try await idle(exit)
        check("shutdown waits for owned child exit before completion", shutdownFinished && !exit.hasLiveChild && exit.linkItems.isEmpty)
        let lock = fixture("lock", input: ["one", "two"]); lock.otherTaskIsBusy = { true }; lock.download(); lock.preview()
        check("batch lock prevents creating or starting rows", !lock.busy && lock.linkItems.isEmpty && events("lock").isEmpty)
        let bad = fixture("bad", input: ["one", "two"], video: false, cover: true); bad.preview(); try await idle(bad)
        let corrupted = Data("{坏记录".utf8), history = base.appendingPathComponent("bad/history.json"); try corrupted.write(to: history)
        bad.confirmAllLinkItems(); try await idle(bad)
        check("first history failure does not overwrite corrupt file or save later rows", bad.records.isEmpty && bad.linkItems.allSatisfy { $0.photoDraft != nil } && (try? Data(contentsOf: history)) == corrupted && (try? fm.contentsOfDirectory(atPath: bad.folder).isEmpty) == true)
        check("history failure reaches parent and blocks later unified save", bad.historyIssue != nil)
        bad.download(); check("failed history keeps all drafts and does not restart workers", !bad.busy && bad.linkItems.allSatisfy { $0.photoDraft != nil }); bad.discardAllLinkItems()
        let large = fixture("large", input: ["one", "two"]); large.text = String(repeating: "x", count: SingleLinkParser.maxTextBytes + 1); large.preview()
        check("oversized input starts no worker or rows", !large.busy && large.linkItems.isEmpty && large.error != nil)
        print("MultiDownloadStoreChecks: \(count) passed")
    }
}
