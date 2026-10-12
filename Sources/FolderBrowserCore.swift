import Foundation
import Darwin

struct FolderBrowserError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Only lists directories and creates a single, explicitly named empty directory.
/// Browsing never edits the library, history, or the selected download destination.
enum FolderBrowser {
    static func directory(_ path: String, writable: Bool = false) throws -> URL {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw FolderBrowserError(message: "请输入完整目录路径，或以 ~/ 开头的路径。")
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try url.resourceValues(forKeys: [.isPackageKey])).isPackage != true else {
            throw FolderBrowserError(message: "文件夹不存在或不是普通目录：\(url.path)")
        }
        if writable && !FileManager.default.isWritableFile(atPath: url.path) {
            throw FolderBrowserError(message: "文件夹不可写，请选择其他保存位置：\(url.path)")
        }
        return url
    }

    static func children(of path: String) throws -> [URL] {
        let parent = try directory(path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]).filter { url in
                // Directory symlinks are usable destinations; application bundles are not.
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
                return try url.resourceValues(forKeys: keys).isPackage != true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func create(name: String, in path: String) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw FolderBrowserError(message: "请填写有效文件夹名称；不能含斜杠、控制字符，或使用 . 和 ..。")
        }
        let parent = try directory(path, writable: true)
        let target = parent.appendingPathComponent(name, isDirectory: true)
        // mkdir without intermediate directories fails even for an existing empty directory.
        // FileManager.createDirectory accepts an existing directory, so use exclusive mkdir.
        guard mkdir(target.path, 0o755) == 0 else {
            let code = errno
            if code == EEXIST {
                throw FolderBrowserError(message: "已有同名文件或文件夹，请换一个名称：\(name)")
            }
            throw FolderBrowserError(message: "创建文件夹失败：\(String(cString: strerror(code)))。位置：\(target.path)")
        }
        return target
    }
}
