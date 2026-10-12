import AVFoundation
import CryptoKit
import Foundation
import SwiftUI

// Thumbnail decoding is tested with its production source; this host supplies only its unused view color.
enum QQTheme { static let blue = Color.blue }

@main
enum InlinePlaybackChecks {
    @MainActor static func main() async {
        do {
            guard (2...3).contains(CommandLine.arguments.count) else { throw Failure("需要本地样本视频路径") }
            let path = CommandLine.arguments[1]
            let sample = URL(fileURLWithPath: path)
            let before = SHA256.hash(data: try Data(contentsOf: sample))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiying-inline-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let playback = ShiyingCardPlayback()
            defer { playback.stopAll() }
            let missing = root.appendingPathComponent("missing.mp4").path
            playback.play(id: UUID(), path: missing)
            try require(playback.player == nil && playback.ownerID == nil && playback.error != nil, "缺失文件不创建播放器")
            let a = UUID(), b = UUID()
            playback.play(id: a, path: path)
            playback.player?.isMuted = true
            guard let old = playback.player, let oldItem = old.currentItem else { throw Failure("本地播放器未创建") }
            try require(playback.ownerID == a && playback.error == nil, "首个播放归属")
            try await until("第一段实际播放推进") { playback.currentTime > 0.1 }
            playback.play(id: b, path: path)
            playback.player?.isMuted = true
            guard let current = playback.player else { throw Failure("切换未创建播放器") }
            try require(current !== old && old.rate == 0 && old.currentItem == nil, "切换停止并释放旧播放")
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
            try await until("第二段实际播放推进") { playback.currentTime > 0.1 }
            try require(playback.ownerID == b && playback.error == nil && !playback.didPlayToEnd, "旧回调不覆盖新播放")
            playback.stop(id: a)
            try require(playback.ownerID == b && playback.player === current, "旧卡片关闭不停止当前卡片")
            let time = playback.currentTime
            try await until("旧卡片关闭后仍推进") { playback.currentTime > time + 0.1 }
            for invalid in [missing, root.path, "https://example.com/video.mp4", "relative.mp4", "file://server/video.mp4"] {
                playback.play(id: a, path: invalid)
                try require(playback.ownerID == b && playback.player === current && playback.error != nil, "拒绝无效路径且保留当前播放")
            }
            playback.play(id: b, path: path)
            playback.player?.isMuted = true
            try await until("结尾检查加载") { playback.duration > 1 }
            guard let ending = playback.player else { throw Failure("结尾播放器缺失") }
            _ = await ending.seek(to: CMTime(seconds: max(0, playback.duration - 0.2), preferredTimescale: 600))
            ending.play()
            try await until("自然播放结束") { playback.didPlayToEnd }
            try require(ending.rate == 0 && playback.progress == 1, "播完暂停")
            try await Task.sleep(nanoseconds: 200_000_000)
            try require(ending.rate == 0 && playback.didPlayToEnd, "不自动循环")
            playback.stopAll()
            try require(playback.ownerID == nil && playback.player == nil && ending.currentItem == nil && ending.rate == 0, "全部关闭释放播放器")
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(playback.ownerID == nil && playback.player == nil && playback.error == nil, "结束后的异步回调不复活播放")
            let cache = ShiyingThumbnailCache(directory: root.appendingPathComponent("thumbnails"))
            guard let image = await cache.image(for: path), image.width > 0, image.height > 0 else { throw Failure("真实视频首帧提取") }
            guard let key = ShiyingThumbnailCache.key(for: sample) else { throw Failure("封面缓存键") }
            try require(FileManager.default.fileExists(atPath: root.appendingPathComponent("thumbnails/" + key + ".jpg").path), "首帧缓存落盘")
            try require(await cache.image(for: missing) == nil, "缺失文件不生成封面")
            if CommandLine.arguments.count == 3 {
                let raw = URL(fileURLWithPath: CommandLine.arguments[2])
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: raw))
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let native = try? await generator.image(at: .zero).image
                try require(native == nil, "回退样本确实无法由 AVFoundation 提取")
                let fallback = await cache.image(for: raw.path)
                try require(fallback?.width == 320 && fallback?.height == 180, "包内 ffmpeg 从文件头提取首帧")
            }
            let covers = MediaCoverChecks.run()
            try require(covers.isEmpty, covers.joined(separator: "；"))
            try require(before == SHA256.hash(data: try Data(contentsOf: sample)), "原媒体内容不变")
            print("PASS actual playback, owner switching, stale callbacks, local-file rejection, natural end, shutdown, first-frame cache and 14 cover identity cases")
        } catch {
            FileHandle.standardError.write(Data(("FAIL " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    @MainActor private static func until(_ name: String, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else { throw Failure(name + "超时") }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    private static func require(_ condition: Bool, _ name: String) throws {
        if !condition { throw Failure(name) }
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
