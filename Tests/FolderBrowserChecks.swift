import Foundation

@main struct FolderBrowserChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("shiying-folder-browser-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ title: String, _ passed: Bool) { precondition(passed, "FAIL " + title); checks += 1; print("PASS " + title) }
        func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let first = try FolderBrowser.create(name: "素材2", in: root.path)
        let second = try FolderBrowser.create(name: "素材10", in: root.path)
        let hidden = root.appendingPathComponent(".隐藏")
        try fm.createDirectory(at: hidden, withIntermediateDirectories: false)
        let bundle = root.appendingPathComponent("不可选.app")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: false)
        let media = root.appendingPathComponent("视频.mp4")
        let original = Data("KEEP ORIGINAL MEDIA".utf8); try original.write(to: media)
        let link = root.appendingPathComponent("目录链接")
        try fm.createSymbolicLink(at: link, withDestinationURL: first)
        try fm.createSymbolicLink(at: root.appendingPathComponent("失效链接"), withDestinationURL: root.appendingPathComponent("缺失"))
        let listed = try FolderBrowser.children(of: root.path)
        check("lists only visible directories, excludes media packages and broken links", Set(listed.map(\.lastPathComponent)) == Set([first.lastPathComponent, second.lastPathComponent, link.lastPathComponent]))
        let names = listed.map(\.lastPathComponent)
        check("natural numeric folder ordering", names.firstIndex(of: first.lastPathComponent)! < names.firstIndex(of: second.lastPathComponent)!)
        check("directory symlink selectable", try FolderBrowser.directory(link.path, writable: true).path == link.path)
        check("tilde and absolute paths normalized", try FolderBrowser.directory("~/").path == fm.homeDirectoryForCurrentUser.path)
        check("reject relative path", rejected { _ = try FolderBrowser.directory("素材2") })
        check("reject nonexistent destination", rejected { _ = try FolderBrowser.directory(root.appendingPathComponent("缺失").path) })
        check("reject file destination", rejected { _ = try FolderBrowser.directory(media.path) })
        check("reject app package destination", rejected { _ = try FolderBrowser.directory(bundle.path) })
        let child = try FolderBrowser.create(name: "  学习子目录  ", in: first.path)
        check("creates one child in requested directory", child.deletingLastPathComponent() == first && child.lastPathComponent == "学习子目录")
        check("reject existing directory without changing it", rejected { _ = try FolderBrowser.create(name: "学习子目录", in: first.path) } && fm.fileExists(atPath: child.path))
        let collisionRejected = rejected { _ = try FolderBrowser.create(name: "视频.mp4", in: root.path) }
        check("reject existing file without overwrite", try collisionRejected && Data(contentsOf: media) == original)
        for name in ["", ".", "..", "../逃逸", "路径/逃逸", "路径\\逃逸", "换\n行", String(repeating: "字", count: 86)] {
            check("reject invalid directory name " + name.debugDescription, rejected { _ = try FolderBrowser.create(name: name, in: root.path) })
        }
        check("browsing and rejected operations preserve existing media", try Data(contentsOf: media) == original)
        let readOnly = try FolderBrowser.create(name: "只读目录", in: root.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        check("reject read-only destination", rejected { _ = try FolderBrowser.directory(readOnly.path, writable: true) })
        check("reject creating in read-only directory", rejected { _ = try FolderBrowser.create(name: "不应创建", in: readOnly.path) })
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
        print("FolderBrowserChecks: \(checks) passed")
    }
}
