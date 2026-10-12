import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main struct PhotoDraftChecks {
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("shiying-draft-" + UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let repo = PhotoDraftRepository(root: base.appendingPathComponent("previews")), target = base.appendingPathComponent("saved")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("原有图片.png"); try Data("KEEP_USER_FILE".utf8).write(to: sentinel)
        var count = 0
        func check(_ name: String, _ ok: Bool) { precondition(ok, "FAIL " + name); count += 1; print("PASS " + name) }
        func png(_ url: URL) throws {
            let context = CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
            let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(writer, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(writer))
        }
        func fixture() throws -> (PhotoDraftJob, URL, [String]) {
            let job = try repo.create(), album = job.directory.appendingPathComponent("测试图文")
            try fm.createDirectory(at: album, withIntermediateDirectories: false)
            let paths = (1...2).map { album.appendingPathComponent(String(format: "%03d.png", $0)).path }
            for path in paths { try png(URL(fileURLWithPath: path)) }
            return (job, album, paths)
        }
        let (job, album, paths) = try fixture()
        try repo.validate(job, album: album.path, paths: paths)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try ShiyingPhotoClipboard.copy(path: paths[0], pasteboard: board)
        try repo.discard(job)
        let pasted = board.data(forType: .png)!, source = CGImageSourceCreateWithData(pasted as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        check("copied full image remains pasteable after both temporary images are deleted", image.width == 2 && image.height == 3 && !fm.fileExists(atPath: job.directory.path) && NSImage(pasteboard: board) != nil)
        check("clipboard contains image bytes and no source file URL", board.types?.contains(.png) == true && board.types?.contains(.fileURL) == false)
        check("cancelling leaves preexisting user file unchanged", try Data(contentsOf: sentinel) == Data("KEEP_USER_FILE".utf8))

        let (outsideJob, outsideAlbum, outsidePaths) = try fixture()
        do { try repo.validate(outsideJob, album: target.path, paths: [sentinel.path]); preconditionFailure("foreign path accepted") }
        catch { check("foreign album cannot become a disposable preview", error.localizedDescription.contains("不属于")) }
        try fm.removeItem(atPath: outsidePaths[0]); try fm.createSymbolicLink(atPath: outsidePaths[0], withDestinationPath: sentinel.path)
        do { try repo.validate(outsideJob, album: outsideAlbum.path, paths: outsidePaths); preconditionFailure("symlink accepted") }
        catch { check("image symlink is rejected", true) }
        try repo.discard(outsideJob)
        check("symlink cleanup never deletes external original", fm.fileExists(atPath: sentinel.path))

        let unknown = repo.root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: unknown, withIntermediateDirectories: false)
        let abandoned = try fixture()
        try repo.recoverAbandoned(confirmed: [])
        check("startup clears owned abandoned preview but keeps unknown directory", !fm.fileExists(atPath: abandoned.0.directory.path) && fm.fileExists(atPath: unknown.path))

        let retained = try fixture(); let bytes = try Data(contentsOf: URL(fileURLWithPath: retained.2[0]))
        let collision = target.appendingPathComponent(retained.1.lastPathComponent)
        try fm.createDirectory(at: collision, withIntermediateDirectories: false)
        let published = try repo.publish(retained.0, album: retained.1.path, paths: retained.2, destination: target.path)
        check("confirmation preserves empty name collision and original image order", try fm.contentsOfDirectory(atPath: collision.path).isEmpty && published.directory.lastPathComponent == "测试图文_1" && published.paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["001.png", "002.png"])
        try repo.finalize(published)
        check("confirmed images remain while temporary files and ownership marker are removed", !fm.fileExists(atPath: retained.0.directory.path) && (try? Data(contentsOf: URL(fileURLWithPath: published.paths[0]))) == bytes && (try? fm.contentsOfDirectory(atPath: published.directory.path).count) == 2)
        try repo.recoverAbandoned(confirmed: [published.directory.path])
        check("confirmed album survives later startup cleanup", fm.fileExists(atPath: published.paths[1]))

        let interrupted = try fixture(); let unconfirmed = try repo.publish(interrupted.0, album: interrupted.1.path, paths: interrupted.2, destination: target.path)
        try repo.recoverAbandoned(confirmed: [])
        check("crash after publishing before history write rolls back unconfirmed copy", !fm.fileExists(atPath: unconfirmed.directory.path) && !fm.fileExists(atPath: interrupted.0.directory.path))
        let savedCrash = try fixture(); let saved = try repo.publish(savedCrash.0, album: savedCrash.1.path, paths: savedCrash.2, destination: target.path)
        try repo.recoverAbandoned(confirmed: [saved.directory.path])
        check("crash after history write retains confirmed files and clears preview", fm.fileExists(atPath: saved.paths[0]) && !fm.fileExists(atPath: savedCrash.0.directory.path))

        let stopped = try fixture()
        do { _ = try repo.publish(stopped.0, album: stopped.1.path, paths: stopped.2, destination: target.path, cancelled: { true }); preconditionFailure("cancel ignored") }
        catch { try repo.rollbackCopies(stopped.0); let members = try fm.contentsOfDirectory(atPath: target.path); check("cancel during confirmation cleans staging and preserves pending originals", fm.fileExists(atPath: stopped.2[0]) && !members.contains { $0.hasPrefix(".shiying-confirm-") }) }
        try repo.discard(stopped.0)
        let modified = try fixture(); let changed = try repo.publish(modified.0, album: modified.1.path, paths: modified.2, destination: target.path)
        try Data("EXTERNAL_EDIT".utf8).write(to: URL(fileURLWithPath: changed.paths[0]))
        do { try repo.recoverAbandoned(confirmed: []); preconditionFailure("external edit deleted") }
        catch { check("recovery retains external edits with explicit location", fm.fileExists(atPath: changed.paths[0]) && error.localizedDescription.contains(changed.directory.path)) }
        print("PhotoDraftChecks: \(count) passed")
    }
}
