import AppKit
import Foundation

@main struct PlatformCoverChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiying-cover-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { FileHandle.standardError.write(Data(("FAIL " + name + "\n").utf8)) }
            precondition(ok, "FAIL " + name); checks += 1
            FileHandle.standardOutput.write(Data(("PASS " + name + "\n").utf8))
        }
        func png(_ width: Int) -> Data {
            NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,
                hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                .representation(using:.png,properties:[:])!
        }
        let url = URL(string:"https://p3.douyinpic.com/test.jpg")!
        check("approved CDN accepts official HTTPS image", PlatformCoverPolicy.approved(url.absoluteString) != nil)
        for url in ["http://p3.douyinpic.com/x", "https://douyinpic.com.evil.example/x", "https://user:secret@p3.douyinpic.com/x", "https://127.0.0.1/x", "https://p3.douyinpic.com:999/x"] {
            check("reject unsafe cover location", PlatformCoverPolicy.approved(url) == nil)
        }
        var redirect = URLRequest(url:url); redirect.setValue("synthetic",forHTTPHeaderField:"Cookie")
        redirect.setValue("synthetic",forHTTPHeaderField:"Authorization")
        let clean = PlatformCoverPolicy.redirectRequest(from:redirect,redirects:0)!
        check("redirect does not carry authentication", clean.value(forHTTPHeaderField:"Cookie") == nil && clean.value(forHTTPHeaderField:"Authorization") == nil)
        check("redirect count is bounded", PlatformCoverPolicy.redirectRequest(from:redirect,redirects:4) == nil)
        let data = png(32)
        check("actual PNG decodes", PlatformCoverDecoder.image(data:data)?.width == 32)
        check("bad image does not pretend to decode", PlatformCoverDecoder.image(data:Data("not an image".utf8)) == nil)
        check("single-image size limit enforced", PlatformCoverDecoder.image(data:Data(count:PlatformCoverDecoder.maxBytes + 1)) == nil)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        ShiyingPlatformCoverCache.store(data,remote:url,cacheRoot:first)
        ShiyingPlatformCoverCache.store(png(48),remote:url,cacheRoot:second)
        check("cache writes only requested independent root", ShiyingPlatformCoverCache.existing(remote:url,cacheRoot:first)?.deletingLastPathComponent() == first.standardizedFileURL.resolvingSymlinksInPath())
        check("path traversal extension rejected", ShiyingPlatformCoverCache.destination(remote:url,ext:"../x",cacheRoot:first) == nil)
        let a = await PlatformCoverLoader.load(remote:url.absoluteString,cacheRoot:first)
        let b = await PlatformCoverLoader.load(remote:url.absoluteString,cacheRoot:second)
        check("memory cache keeps data roots isolated", a?.width == 32 && b?.width == 48)
        let foreign = first.appendingPathComponent("user-note.txt");try Data("keep".utf8).write(to:foreign)
        for n in 0...ShiyingPlatformCoverCache.fileLimit {
            ShiyingPlatformCoverCache.store(data,remote:URL(string:"https://p3.douyinpic.com/\(n).png")!,cacheRoot:first)
        }
        let files = try FileManager.default.contentsOfDirectory(at:first,includingPropertiesForKeys:nil)
        check("owned cache file count bounded", files.filter { $0.pathExtension == "png" }.count <= ShiyingPlatformCoverCache.fileLimit)
        check("cache pruning preserves foreign files", try Data(contentsOf:foreign) == Data("keep".utf8))
        print("PlatformCoverChecks: \(checks) passed")
    }
}
