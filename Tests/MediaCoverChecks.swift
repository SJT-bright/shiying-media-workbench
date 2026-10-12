import Foundation

enum MediaCoverChecks {
    static func run() -> [String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shiying-cover-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            return try evaluate(root)
        } catch {
            return ["无法准备临时目录：" + error.localizedDescription]
        }
    }

    private static func evaluate(_ root: URL) throws -> [String] {
        let own = root.appendingPathComponent("own.mp4").path
        let borrowed = root.appendingPathComponent("borrowed.mp4").path
        let later = root.appendingPathComponent("later.mp4").path
        let other = root.appendingPathComponent("other-work.mp4").path
        let image = root.appendingPathComponent("still.jpg").path
        let folder = root.appendingPathComponent("dir", isDirectory: true).path
        let preferredFile = root.appendingPathComponent("preferred.mp4").path
        try Data([0x00]).write(to: URL(fileURLWithPath: borrowed))
        try Data([0x00]).write(to: URL(fileURLWithPath: later))
        try Data([0x00]).write(to: URL(fileURLWithPath: other))
        try Data([0x00]).write(to: URL(fileURLWithPath: image))
        try Data([0x00]).write(to: URL(fileURLWithPath: preferredFile))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let id = "7123456789012345678"
        let otherID = "7123456789012345679"
        let link = "https://www.douyin.com/video/" + id
        let noteLink = "https://www.douyin.com/note/" + id
        let shortLink = "https://v.douyin.com/short/"
        let otherLink = "https://www.douyin.com/video/" + otherID
        let bili = "https://www.bilibili.com/video/BV1a2b3c4d5e"
        let biliOther = "https://www.bilibili.com/video/BV1a2b3c4d5f"
        let biliAV = "https://www.bilibili.com/video/av12345"
        let wechat = "https://channels.weixin.qq.com/sph/AbcdEf12"
        let wechatObjectLink = "https://channels.weixin.qq.com/"
        let xhs = "https://www.xiaohongshu.com/explore/same-title"

        let library = [
            ShiyingCoverCandidate(link: otherLink, videoID: nil, path: other, imagePaths: [image]),
            ShiyingCoverCandidate(link: link, videoID: nil, path: own, imagePaths: nil),
            ShiyingCoverCandidate(link: noteLink, videoID: nil, path: borrowed, imagePaths: [image]),
            ShiyingCoverCandidate(link: link, videoID: id, path: later, imagePaths: nil)
        ]

        var failures: [String] = []
        func expect(_ name: String, _ value: String?, _ expected: String?) {
            if value != expected {
                failures.append(name + " 得到 " + (value ?? "nil") + "，期望 " + (expected ?? "nil"))
            }
        }

        expect("主文件优先", ShiyingCoverResolver.path(link: link, videoID: nil, preferred: preferredFile, candidates: library), preferredFile)
        expect("缺失不返回主路径", ShiyingCoverResolver.path(link: link, videoID: nil, preferred: own, candidates: library), borrowed)
        expect("短链加视频号对齐同一作品", ShiyingCoverResolver.path(link: shortLink, videoID: id, preferred: nil, candidates: library), borrowed)
        expect("别的作品不借", ShiyingCoverResolver.path(link: otherLink, videoID: nil, preferred: nil, candidates: [
            ShiyingCoverCandidate(link: link, videoID: nil, path: borrowed, imagePaths: [image])
        ]), nil)
        expect("同目录不同作品", ShiyingCoverResolver.path(link: otherLink, videoID: nil, preferred: folder, candidates: [
            ShiyingCoverCandidate(link: link, videoID: nil, path: borrowed, imagePaths: nil)
        ]), nil)
        expect("没有作品号", ShiyingCoverResolver.path(link: xhs, videoID: "same-title", preferred: own, candidates: library), nil)
        expect("无作品号时主文件仍可用", ShiyingCoverResolver.path(link: xhs, videoID: nil, preferred: preferredFile, candidates: []), preferredFile)
        expect("相对路径不作封面", ShiyingCoverResolver.path(link: link, videoID: nil, preferred: "borrowed.mp4", candidates: library), borrowed)
        expect("目录拒绝后借用", ShiyingCoverResolver.path(link: link, videoID: nil, preferred: folder, candidates: library), borrowed)
        expect("视频优先于更早的图片", ShiyingCoverResolver.path(link: link, videoID: nil, preferred: nil, candidates: [
            ShiyingCoverCandidate(link: link, videoID: nil, path: nil, imagePaths: [image]),
            ShiyingCoverCandidate(link: link, videoID: nil, path: later, imagePaths: nil)
        ]), later)
        expect("没有视频时用同一作品图片", ShiyingCoverResolver.path(link: link, videoID: nil, preferred: nil, candidates: [
            ShiyingCoverCandidate(link: link, videoID: nil, path: own, imagePaths: [image])
        ]), image)
        expect("B站同一BV", ShiyingCoverResolver.path(link: bili, videoID: nil, preferred: nil, candidates: [
            ShiyingCoverCandidate(link: biliAV, videoID: nil, path: other, imagePaths: nil),
            ShiyingCoverCandidate(link: biliOther, videoID: nil, path: other, imagePaths: nil),
            ShiyingCoverCandidate(link: bili, videoID: nil, path: borrowed, imagePaths: nil)
        ]), borrowed)
        expect("视频号分享号不匹配object", ShiyingCoverResolver.path(link: wechat, videoID: nil, preferred: nil, candidates: [
            ShiyingCoverCandidate(link: wechatObjectLink, videoID: "AbcdEf12", path: other, imagePaths: nil),
            ShiyingCoverCandidate(link: wechat, videoID: nil, path: borrowed, imagePaths: nil)
        ]), borrowed)
        expect("空候选", ShiyingCoverResolver.path(link: link, videoID: id, preferred: nil, candidates: []), nil)
        return failures
    }
}
