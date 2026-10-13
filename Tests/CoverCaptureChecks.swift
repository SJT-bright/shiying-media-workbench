import Foundation
import AppKit
import ImageIO
import Darwin

@main struct CoverCaptureChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("shiying-cover-checks-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            CoverCaptureStore.dataRootOverride = nil; CoverCaptureStore.workerOverrideURL = nil
            try? fm.removeItem(at: base)
        }
        precondition(CommandLine.arguments.count > 1, "offline worker path is required")
        CoverCaptureStore.workerOverrideURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var count = 0
        func check(_ name: String, _ ok: Bool) {
            precondition(ok, "FAIL " + name); count += 1; print("PASS " + name)
        }
        func post(_ id: String, _ variant: String = "good", cover: Bool = true) -> CreatorPost {
            CreatorPost(id: id, link: "https://www.douyin.com/video/" + id, title: "标题 " + id, author: "离线测试",
                        cover: cover ? "https://example.invalid/" + variant : nil, isVideo: true)
        }
        func fixture(_ name: String) throws -> (CoverCaptureStore, URL, URL) {
            let root = base.appendingPathComponent(name), destination = root.appendingPathComponent("saved")
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            CoverCaptureStore.dataRootOverride = root
            return (CoverCaptureStore(), root, destination)
        }
        func idle(_ store: CoverCaptureStore) async throws {
            for _ in 0..<500 {
                if !store.busy && !store.saving { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            preconditionFailure("cover worker did not settle")
        }
        func start(_ store: CoverCaptureStore, _ posts: [CreatorPost], _ destination: URL) {
            store.begin(posts: posts, sourceURL: "https://www.douyin.com/user/frozen-author", quality: .balanced, folder: destination.path)
        }
        func tempEmpty(_ root: URL) -> Bool {
            (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("cover-previews").path).isEmpty) ?? true
        }
        func savedEmpty(_ root: URL) -> Bool { (try? fm.contentsOfDirectory(atPath: root.path).isEmpty) == true }
        func waitWorker(_ root: URL) async throws -> (URL, Int32) {
            let previews = root.appendingPathComponent("cover-previews")
            for _ in 0..<250 {
                if let files = try? fm.contentsOfDirectory(at: previews, includingPropertiesForKeys: nil),
                   let job = files.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("started").path) }),
                   let value = try? String(contentsOf: job.appendingPathComponent("worker.pid"), encoding: .utf8), let pid = Int32(value) {
                    return (job, pid)
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            preconditionFailure("slow worker did not start")
        }

        check("capture defaults retain video-only behavior", CaptureSelection() == CaptureSelection(video: true, cover: false))
        check("legacy missing option keys retain video-only behavior", try JSONDecoder().decode(CaptureSelection.self, from: Data("{}".utf8)) == CaptureSelection())
        check("both checkboxes and cover-only are valid; empty selection is invalid", CaptureSelection(video: true, cover: true).isValid && CaptureSelection(video: false, cover: true).isValid && !CaptureSelection(video: false, cover: false).isValid)

        let (store, root, destination) = try fixture("confirm")
        let sentinel = destination.appendingPathComponent("用户原文件.txt")
        try Data("KEEP_USER_FILE".utf8).write(to: sentinel)
        start(store, [post("1"), post("2")], destination); try await idle(store)
        check("two covers download temporarily without history or formal image copies", store.draftRecords.count == 2 && store.canConfirm && !fm.fileExists(atPath: root.appendingPathComponent("history.json").path) && (try? fm.contentsOfDirectory(atPath: destination.path)) == ["用户原文件.txt"])
        check("source, real post IDs, links and selected quality are frozen", store.frozenSourceURL.hasSuffix("frozen-author") && store.draftRecords.map(\.videoID) == ["1", "2"] && store.draftRecords.allSatisfy { $0.quality == .balanced && $0.link.contains("/video/") && $0.isCover && $0.isAlbum })
        let temporary = store.draftRecords.flatMap { $0.imagePaths ?? [] }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try ShiyingPhotoClipboard.copy(path: temporary[0], pasteboard: board)
        var accepted: [Record] = [], confirmation: Bool?, callbackIdle = false, commits = 0
        store.confirm(destination: destination.path, commit: { records in
            commits += 1
            do { try HistoryRepository<Record>(fileURL: root.appendingPathComponent("history.json")).save(records); accepted = records; return true }
            catch { return false }
        }, completion: { ok in confirmation = ok; callbackIdle = !store.busy && !store.saving })
        try await idle(store)
        check("one history transaction accepts all completed cover records", commits == 1 && confirmation == true && callbackIdle && accepted.count == 2 && accepted.allSatisfy { $0.isCover && $0.status == "完成" && $0.imagePaths?.count == 1 })
        check("successful confirmation clears original previews and keeps published images", temporary.allSatisfy { !fm.fileExists(atPath: $0) } && tempEmpty(root) && accepted.flatMap { $0.imagePaths ?? [] }.allSatisfy { fm.fileExists(atPath: $0) })
        let restarted = CoverCaptureStore()
        check("restart preserves all saved cover bytes", !restarted.hasDrafts && accepted.flatMap { $0.imagePaths ?? [] }.allSatisfy { fm.fileExists(atPath: $0) })
        check("clipboard retains full PNG bytes without a file URL after preview cleanup", board.data(forType: .png).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.map { CGImageSourceCreateImageAtIndex($0, 0, nil)?.height == 3 } == true && board.types?.contains(.fileURL) == false)
        check("preexisting user file remains byte-identical", try Data(contentsOf: sentinel) == Data("KEEP_USER_FILE".utf8))

        let (cancel, cancelRoot, cancelDestination) = try fixture("cancel")
        start(cancel, [post("3"), post("4")], cancelDestination); try await idle(cancel)
        let cancelPaths = cancel.draftRecords.flatMap { $0.imagePaths ?? [] }
        try ShiyingPhotoClipboard.copy(path: cancelPaths[0], pasteboard: board)
        cancel.discard(); try await idle(cancel)
        check("cancel deletes every owned cover preview without a saved copy", cancelPaths.allSatisfy { !fm.fileExists(atPath: $0) } && tempEmpty(cancelRoot) && savedEmpty(cancelDestination) && !cancel.hasDrafts)
        check("copied image remains pasteable after cancel deletes originals", NSImage(pasteboard: board) != nil && board.data(forType: .png) != nil)

        let (changed, changedRoot, changedDestination) = try fixture("changed")
        start(changed, [post("5")], changedDestination); try await idle(changed)
        let changedPath = changed.draftRecords[0].imagePaths![0]
        start(changed, [post("6")], changedDestination); try await idle(changed)
        check("starting another group clears the old group and cannot mix stale results", !fm.fileExists(atPath: changedPath) && changed.draftRecords.map(\.videoID) == ["6"] && (try? fm.contentsOfDirectory(atPath: changedRoot.appendingPathComponent("cover-previews").path).count) == 1)
        changed.discard(); try await idle(changed)

        let (failed, failedRoot, failedDestination) = try fixture("failed")
        start(failed, [post("7"), post("8", "fail"), post("9", cover: false)], failedDestination); try await idle(failed)
        var rejectedCommit = false, rejectedConfirmation: Bool?
        failed.confirm(destination: failedDestination.path, commit: { _ in rejectedCommit = true; return true }, completion: { rejectedConfirmation = $0 })
        check("failed or missing covers are individually reported and prohibit partial confirmation", failed.failures.map(\.id) == ["8", "9"] && failed.draftRecords.count == 1 && !failed.canConfirm && !rejectedCommit && rejectedConfirmation == false && savedEmpty(failedDestination))
        failed.discard(); try await idle(failed)
        check("cancel clears successful previews and failed-worker UUID jobs together", tempEmpty(failedRoot) && !failed.hasDrafts)

        let (rollback, rollbackRoot, rollbackDestination) = try fixture("rollback")
        start(rollback, [post("10"), post("11")], rollbackDestination); try await idle(rollback)
        let rollbackPaths = rollback.draftRecords.flatMap { $0.imagePaths ?? [] }
        var rollbackResult: Bool?
        rollback.confirm(destination: rollbackDestination.path, commit: { _ in false }, completion: { rollbackResult = $0 })
        try await idle(rollback)
        check("history rejection rolls back every published copy and retains all originals", rollbackResult == false && rollbackPaths.allSatisfy { fm.fileExists(atPath: $0) } && rollback.draftRecords.count == 2 && savedEmpty(rollbackDestination) && rollback.canConfirm)
        rollback.discard(); try await idle(rollback)
        check("history rejection can later be cancelled without residue", tempEmpty(rollbackRoot))

        let (modified, modifiedRoot, modifiedDestination) = try fixture("modified-preview")
        start(modified, [post("30")], modifiedDestination); try await idle(modified)
        let modifiedPath = modified.draftRecords[0].imagePaths![0]
        let original = try Data(contentsOf: URL(fileURLWithPath: modifiedPath))
        let recolored = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAEUlEQVR4nGPQbLz8H4QZMBgAwNsO6QZtERUAAAAASUVORK5CYII=")!
        precondition(recolored.count == original.count && recolored != original)
        try recolored.write(to: URL(fileURLWithPath: modifiedPath))
        var modifiedCommit = false, modifiedResult: Bool?
        modified.confirm(destination: modifiedDestination.path, commit: { _ in modifiedCommit = true; return true }, completion: { modifiedResult = $0 })
        try await idle(modified)
        check("same-size valid image replacement after download fails the frozen byte hash", modifiedResult == false && !modifiedCommit && savedEmpty(modifiedDestination) && modified.error?.contains("被外部修改") == true && (try? Data(contentsOf: URL(fileURLWithPath: modifiedPath))) == recolored)
        modified.discard(); try await idle(modified)
        check("cancel after modified preview clears only its owned temporary group", tempEmpty(modifiedRoot))

        let (savingCancel, savingCancelRoot, savingCancelDestination) = try fixture("saving-cancel")
        start(savingCancel, [post("12"), post("13")], savingCancelDestination); try await idle(savingCancel)
        var saveCancelledResult: Bool?, saveCancelledCommit = false
        savingCancel.confirm(destination: savingCancelDestination.path, commit: { _ in saveCancelledCommit = true; return true }, completion: { saveCancelledResult = $0 })
        savingCancel.discard(); try await idle(savingCancel)
        check("cancel during confirmation settles publication before clearing previews", saveCancelledResult == false && !saveCancelledCommit && tempEmpty(savingCancelRoot) && savedEmpty(savingCancelDestination))

        let (slow, slowRoot, slowDestination) = try fixture("slow")
        start(slow, [post("14", "slow"), post("15")], slowDestination)
        let (_, slowPID) = try await waitWorker(slowRoot)
        slow.discard(); try await idle(slow)
        check("cancel during download waits for owned worker exit then cleans its UUID directory", kill(slowPID, 0) == -1 && errno == ESRCH && tempEmpty(slowRoot) && !slow.hasDrafts && savedEmpty(slowDestination))
        start(slow, [post("16")], slowDestination); try await idle(slow)
        check("new download after cancellation cannot receive old worker results", slow.draftRecords.map(\.videoID) == ["16"] && slow.failures.isEmpty)
        slow.discard(); try await idle(slow)

        let (quit, quitRoot, quitDestination) = try fixture("quit")
        start(quit, [post("17", "slow")], quitDestination)
        let (_, quitPID) = try await waitWorker(quitRoot)
        var shutdownCount = 0, shutdownSettled = false
        quit.shutdown(completion: { shutdownCount += 1; shutdownSettled = !quit.busy && !quit.saving && tempEmpty(quitRoot) })
        try await idle(quit)
        check("shutdown callback runs once after worker exit and cache cleanup", shutdownCount == 1 && shutdownSettled && kill(quitPID, 0) == -1)

        let (abandoned, abandonedRoot, abandonedDestination) = try fixture("abandoned")
        start(abandoned, [post("18"), post("19")], abandonedDestination); try await idle(abandoned)
        let abandonedPaths = abandoned.draftRecords.flatMap { $0.imagePaths ?? [] }
        let unknown = abandonedRoot.appendingPathComponent("cover-previews").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: unknown, withIntermediateDirectories: false)
        let restart = CoverCaptureStore()
        check("startup recovers owned abandoned covers and preserves unknown directories", !restart.hasDrafts && abandonedPaths.allSatisfy { !fm.fileExists(atPath: $0) } && fm.fileExists(atPath: unknown.path))

        let (crash, crashRoot, crashDestination) = try fixture("crash")
        start(crash, [post("20")], crashDestination); try await idle(crash)
        let draft = crash.draftRecords[0], jobURL = URL(fileURLWithPath: draft.path!).deletingLastPathComponent()
        let repository = PhotoDraftRepository(root: crashRoot.appendingPathComponent("cover-previews"))
        let job = PhotoDraftJob(id: UUID(uuidString: jobURL.lastPathComponent)!, directory: jobURL)
        let unconfirmed = try repository.publish(job, album: draft.path!, paths: draft.imagePaths!, destination: crashDestination.path)
        _ = CoverCaptureStore()
        check("restart before history commit removes published unconfirmed covers", !fm.fileExists(atPath: unconfirmed.directory.path) && tempEmpty(crashRoot))

        let (unreadable, unreadableRoot, unreadableDestination) = try fixture("unreadable-history")
        start(unreadable, [post("31")], unreadableDestination); try await idle(unreadable)
        let unreadableDraft = unreadable.draftRecords[0], unreadableJobURL = URL(fileURLWithPath: unreadableDraft.path!).deletingLastPathComponent()
        let unreadableRepository = PhotoDraftRepository(root: unreadableRoot.appendingPathComponent("cover-previews"))
        let unreadableJob = PhotoDraftJob(id: UUID(uuidString: unreadableJobURL.lastPathComponent)!, directory: unreadableJobURL)
        let uncertain = try unreadableRepository.publish(unreadableJob, album: unreadableDraft.path!, paths: unreadableDraft.imagePaths!, destination: unreadableDestination.path)
        let malformed = Data("{坏JSON".utf8)
        try malformed.write(to: unreadableRoot.appendingPathComponent("history.json"))
        let unreadableRestart = CoverCaptureStore()
        start(unreadableRestart, [post("32")], unreadableDestination)
        check("unreadable history preserves an uncertain published cover and blocks new downloads", !unreadableRestart.busy && unreadableRestart.error?.contains("未解决") == true && uncertain.paths.allSatisfy { fm.fileExists(atPath: $0) } && (try? Data(contentsOf: unreadableRoot.appendingPathComponent("history.json"))) == malformed)
        var uncertainCleanup: Bool?
        unreadableRestart.discard(completion: { uncertainCleanup = $0 }); try await idle(unreadableRestart)
        check("discard reports incomplete cleanup instead of deleting uncertain saved media", uncertainCleanup == false && uncertain.paths.allSatisfy { fm.fileExists(atPath: $0) })

        let (savedCrash, savedCrashRoot, savedCrashDestination) = try fixture("saved-crash")
        start(savedCrash, [post("21")], savedCrashDestination); try await idle(savedCrash)
        var savedDraft = savedCrash.draftRecords[0]
        let savedJobURL = URL(fileURLWithPath: savedDraft.path!).deletingLastPathComponent()
        let savedRepository = PhotoDraftRepository(root: savedCrashRoot.appendingPathComponent("cover-previews"))
        let savedJob = PhotoDraftJob(id: UUID(uuidString: savedJobURL.lastPathComponent)!, directory: savedJobURL)
        let savedPublication = try savedRepository.publish(savedJob, album: savedDraft.path!, paths: savedDraft.imagePaths!, destination: savedCrashDestination.path)
        savedDraft.path = savedPublication.directory.path; savedDraft.imagePaths = savedPublication.paths; savedDraft.status = "完成"
        try HistoryRepository<Record>(fileURL: savedCrashRoot.appendingPathComponent("history.json")).save([savedDraft])
        _ = CoverCaptureStore()
        check("restart after history commit preserves cover bytes and clears cache ownership", savedPublication.paths.allSatisfy { fm.fileExists(atPath: $0) } && tempEmpty(savedCrashRoot) && !fm.fileExists(atPath: savedPublication.directory.appendingPathComponent(".shiying-photo-owner").path))

        let (external, externalRoot, externalDestination) = try fixture("external")
        start(external, [post("22"), post("23")], externalDestination); try await idle(external)
        var alteredPath: String?
        external.confirm(destination: externalDestination.path, commit: { records in
            alteredPath = records[0].imagePaths![0]
            try! Data("EXTERNAL_EDIT".utf8).write(to: URL(fileURLWithPath: alteredPath!))
            return false
        }, completion: { _ in })
        try await idle(external)
        check("rollback preserves an externally modified image and blocks further confirmation", alteredPath.map { (try? Data(contentsOf: URL(fileURLWithPath: $0))) == Data("EXTERNAL_EDIT".utf8) } == true && !external.canConfirm && external.error?.contains("回滚") == true)
        external.discard(); try await idle(external)
        check("cancel retains externally modified publication with its explicit location", alteredPath.map { fm.fileExists(atPath: $0) } == true && external.error?.contains(externalDestination.path) == true && !tempEmpty(externalRoot))

        let (oversized, oversizedRoot, oversizedDestination) = try fixture("oversized")
        start(oversized, [post("24", "flood")], oversizedDestination); try await idle(oversized)
        check("unbounded worker stdout is stopped and never accepted as a cover", oversized.failures.count == 1 && !oversized.hasDrafts && oversized.error?.contains("输出超限") == true)
        oversized.discard(); try await idle(oversized)
        check("output-limit failure can clean every owned temporary file", tempEmpty(oversizedRoot))
        print("CoverCaptureChecks: \(count) passed")
    }
}
