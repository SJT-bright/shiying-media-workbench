import Foundation

@main struct CollectionOrganizationChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiying-folders-" + UUID().uuidString)
        defer { BatchRepository.collectionMoveFailureForTesting = nil; try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ name: String, _ ok: Bool) { precondition(ok, "FAIL " + name); checks += 1; print("PASS " + name) }
        let fm = FileManager.default
        struct Fixture {
            let repo: BatchRepository; let state: BatchLibraryState
            let source: URL; let target: URL; let history: URL
        }
        func fixture(_ name: String) throws -> Fixture {
            let support = root.appendingPathComponent(name), parent = support.appendingPathComponent("资料")
            let repo = BatchRepository(rootURL: support.appendingPathComponent("batch"))
            let source = try BatchRepository.createCollection(name: "博主原始素材", parent: parent, existing: [])
            let target = try BatchRepository.createCollection(name: "开头钩子", parent: parent, existing: [source])
            var child = try BatchRepository.createCollection(name: "对比样本", parent: URL(fileURLWithPath: source.path), existing: [source,target])
            child.parentID = source.id
            let video = URL(fileURLWithPath: child.path).appendingPathComponent("原片.mp4")
            let audio = URL(fileURLWithPath: child.path).appendingPathComponent("原片.m4a")
            try Data("VIDEO_UNCHANGED".utf8).write(to: video); try Data("AUDIO_UNCHANGED".utf8).write(to: audio)
            var item = BatchItem(collectionID: child.id, link: "https://www.douyin.com/video/7000000000000000001", sourceText: "原始分享")
            item.path = video.path; item.audioPath = audio.path; item.status = .completed
            var state = BatchLibraryState(); state.collections = [source,target,child]; state.items = [item]
            try repo.save(state)
            let history = support.appendingPathComponent("history.json")
            try JSONSerialization.data(withJSONObject: [["folder": child.path, "path": video.path, "title": "保留未知字段", "unrelated": 42]], options: [.sortedKeys]).write(to: history)
            return Fixture(repo: repo, state: state, source: URL(fileURLWithPath: source.path), target: URL(fileURLWithPath: target.path), history: history)
        }
        let legacy = Data("{\"name\":\"旧文件夹\",\"path\":\"/tmp/legacy\"}".utf8)
        let old = try BatchRepository.decoder.decode(StudyCollection.self, from: legacy)
        check("legacy folders default to root and empty notes", old.parentID == nil && old.notes.isEmpty)
        check("multiline Chinese notes preserved", try CollectionOrganization.editedNotes("  标题分析\n观察开头钩子  ") == "标题分析\n观察开头钩子")
        do { _ = try CollectionOrganization.editedNotes(String(repeating: "长", count: 12_000)); preconditionFailure("oversized notes accepted") }
        catch { check("oversized notes have specific error", error.localizedDescription.contains("32 KiB")) }

        let f = try fixture("success"), id = f.state.collections[0].id, targetID = f.state.collections[1].id
        let moved = try f.repo.moveCollection(id, to: targetID, rootDirectory: f.target.deletingLastPathComponent(), expected: f.state)
        let destination = f.target.appendingPathComponent(f.source.lastPathComponent)
        check("real directory moved into target without copying media", !fm.fileExists(atPath:f.source.path) && fm.fileExists(atPath:destination.path))
        check("folder parent and descendants updated", moved.collections[0].parentID == targetID && moved.collections[2].path.hasPrefix(destination.path + "/"))
        check("video bytes and paired audio stay intact", try Data(contentsOf: URL(fileURLWithPath:moved.items[0].path!)) == Data("VIDEO_UNCHANGED".utf8) && Data(contentsOf: URL(fileURLWithPath:moved.items[0].audioPath!)) == Data("AUDIO_UNCHANGED".utf8))
        check("source provenance preserved", moved.items[0].sourceText == f.state.items[0].sourceText && moved.items[0].id == f.state.items[0].id)
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf:f.history)) as! [[String:Any]]
        check("single history location updated and other fields preserved", history[0]["path"] as? String == moved.items[0].path && history[0]["unrelated"] as? Int == 42)
        check("restart reads moved state and journal cleaned", try f.repo.load() == moved && !fm.fileExists(atPath:f.repo.moveJournalURL.path))
        let restored = try f.repo.moveCollection(id, to:nil, rootDirectory:f.source.deletingLastPathComponent(), expected:moved)
        check("move back restores directory and original media paths", fm.fileExists(atPath:f.source.path) && restored.items[0].path == f.state.items[0].path)
        check("prefix neighbor must not be rewritten", CollectionOrganization.relocated(f.source.path + "-other/v.mp4", from:f.source.path, to:destination.path) == f.source.path + "-other/v.mp4")

        let photos = try fixture("photo-paths")
        var photoState = photos.state
        let album = photos.source.appendingPathComponent("图文"), image = album.appendingPathComponent("001.webp")
        try fm.createDirectory(at: album, withIntermediateDirectories: true)
        try Data("PHOTO_UNCHANGED".utf8).write(to: image)
        var photoItem = BatchItem(collectionID: photoState.collections[0].id, link: "https://www.douyin.com/note/7000000000000000002", sourceText: "图文分享")
        photoItem.status = .completed; photoItem.mediaKind = "image_album"; photoItem.path = album.path; photoItem.imagePaths = [image.path]
        photoState.items.append(photoItem); try photos.repo.save(photoState)
        try JSONSerialization.data(withJSONObject: [["path": album.path, "imagePaths": [image.path], "mediaKind": "image_album", "unrelated": 42]]).write(to: photos.history)
        let photoMoved = try photos.repo.moveCollection(photoState.collections[0].id, to: photoState.collections[1].id, rootDirectory: photos.source.deletingLastPathComponent(), expected: photoState)
        let movedImage = photoMoved.items[1].imagePaths![0]
        check("album image paths move with collection and original bytes", movedImage.hasPrefix(photos.target.path + "/") && (try? Data(contentsOf: URL(fileURLWithPath: movedImage))) == Data("PHOTO_UNCHANGED".utf8))
        let photoHistory = try JSONSerialization.jsonObject(with: Data(contentsOf: photos.history)) as! [[String: Any]]
        check("single album history paths move without losing fields", photoHistory[0]["imagePaths"] as? [String] == [movedImage] && photoHistory[0]["unrelated"] as? Int == 42)
        check("album kind and ordered paths survive restart", try photos.repo.load().items[1] == photoMoved.items[1] && photoMoved.items[1].isAlbum)
        let legacyItem = try BatchRepository.encoder.encode(f.state.items[0])
        check("legacy video remains video without album fields", try !BatchRepository.decoder.decode(BatchItem.self, from: legacyItem).isAlbum)

        do { _ = try f.repo.moveCollection(id, to:f.state.collections[2].id, rootDirectory:f.source.deletingLastPathComponent(), expected:restored); preconditionFailure("cycle accepted") }
        catch { check("own descendant rejected with actionable reason", error.localizedDescription.contains("自己")) }
        let conflict = try fixture("conflict")
        let conflictPath = conflict.target.appendingPathComponent(conflict.source.lastPathComponent)
        try fm.createDirectory(at: conflictPath, withIntermediateDirectories:true)
        let sentinel = conflictPath.appendingPathComponent("用户内容.txt"); try Data("KEEP".utf8).write(to:sentinel)
        do { _ = try conflict.repo.moveCollection(conflict.state.collections[0].id, to:conflict.state.collections[1].id, rootDirectory:conflict.source.deletingLastPathComponent(), expected:conflict.state); preconditionFailure("overwrote conflict") }
        catch { check("name collision preserves both directories and sentinel", fm.fileExists(atPath:conflict.source.path) && (try? Data(contentsOf:sentinel)) == Data("KEEP".utf8) && error.localizedDescription.contains("同名")) }

        for phase in ["afterDirectoryRename", "afterLibraryWrite"] {
            let fault = try fixture(phase), before = try Data(contentsOf:fault.history)
            BatchRepository.collectionMoveFailureForTesting = { whereAt in if whereAt == phase { throw CollectionOrganizationError(message:"合成落盘故障") } }
            do { _ = try fault.repo.moveCollection(fault.state.collections[0].id, to:fault.state.collections[1].id, rootDirectory:fault.source.deletingLastPathComponent(), expected:fault.state); preconditionFailure("fault not raised") }
            catch { check("\(phase) rolls back physical location", fm.fileExists(atPath:fault.source.path) && error.localizedDescription.contains("恢复原位置")) }
            BatchRepository.collectionMoveFailureForTesting = nil
            check("\(phase) restores library and history", try fault.repo.load() == fault.state && Data(contentsOf:fault.history) == before)
        }

        for stage in ["prepared", "renamed", "libraryOnly", "complete"] {
            let crash = try fixture("crash-" + stage)
            let source = crash.source.path, destination = crash.target.appendingPathComponent(crash.source.lastPathComponent).path
            var next = crash.state; next.collections[0].parentID = next.collections[1].id
            for i in next.collections.indices { next.collections[i].path = CollectionOrganization.relocated(next.collections[i].path, from:source, to:destination) }
            next.items[0].path = CollectionOrganization.relocated(next.items[0].path!, from:source, to:destination)
            next.items[0].audioPath = CollectionOrganization.relocated(next.items[0].audioPath!, from:source, to:destination)
            let file = crash.repo.rootURL.appendingPathComponent(BatchRepository.fileName)
            let before = try Data(contentsOf:file), after = try BatchRepository.encoder.encode(next), historyBefore = try Data(contentsOf:crash.history)
            let historyAfter = try JSONSerialization.data(withJSONObject:[["folder": next.collections[2].path, "path":next.items[0].path!, "title":"保留未知字段", "unrelated":42]], options:[.sortedKeys])
            let journal = CollectionMoveJournal(source:source,destination:destination,before:before,after:after,historyBefore:historyBefore,historyAfter:historyAfter)
            try BatchRepository.encoder.encode(journal).write(to:crash.repo.moveJournalURL)
            if stage != "prepared" { try fm.moveItem(atPath:source,toPath:destination) }
            if stage == "libraryOnly" || stage == "complete" { try after.write(to:file) }
            if stage == "complete" { try historyAfter.write(to:crash.history) }
            let recovered = try crash.repo.load()
            check("crash \(stage) produces coherent library and directory", recovered == (stage == "complete" ? next : crash.state) && fm.fileExists(atPath:stage == "complete" ? destination : source))
            check("crash \(stage) preserves correct history and clears receipt", try Data(contentsOf:crash.history) == (stage == "complete" ? historyAfter : historyBefore) && !fm.fileExists(atPath:crash.repo.moveJournalURL.path))
        }
        var folders = f.state.collections
        CollectionOrganization.reorder(folders[1].id, by:-1, in:&folders)
        check("reorder changes root siblings only", folders[0].id == targetID && folders[2].parentID == id)
        print("CollectionOrganizationChecks: \(checks) passed")
    }
}
