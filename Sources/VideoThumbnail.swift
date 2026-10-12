import SwiftUI
import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// 只管理本 App 为封面创建的解码进程，退出时不留下后台子进程。
enum ShiyingThumbnailProcesses {
    private static let lock = NSLock()
    private static var running: [Int32: Process] = [:]
    private static var accepting = true

    static func start(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }
        do { try process.run(); running[process.processIdentifier] = process; return true }
        catch { return false }
    }
    static func finished(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        running[process.processIdentifier] = nil
    }
    static func cancelAll() {
        lock.lock()
        accepting = false
        let processes = Array(running.values)
        running.removeAll()
        lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
    }
}

/// 缩略图只读取已保存的视频，不联网、不改媒体文件或下载记录。
actor ShiyingThumbnailCache {
    static let shared = ShiyingThumbnailCache()

    private final class ImageBox: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private let directory: URL
    private let memory = NSCache<NSString, ImageBox>()
    private var pending: [String: Task<CGImage?, Never>] = [:]
    private var failed: Set<String> = []
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(directory: URL? = nil) {
        self.directory = directory
            ?? shiyingTestDataRoot(fallback: "/tmp/shiying-thumbnail-test")?.appendingPathComponent("thumbnails")
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("拾影/video-thumbnails-first-frame-v3", isDirectory: true)
        memory.countLimit = 128
        memory.totalCostLimit = 24 * 1024 * 1024
    }

    /// 路径、长度或修改时间改变即用新键，移动/替换文件不会显示旧图。
    static func key(for url: URL) -> String? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize,
              let date = values.contentModificationDate else { return nil }
        let identity = "v3-first-frame|\(url.standardizedFileURL.path)|\(size)|\(date.timeIntervalSinceReferenceDate)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func image(for path: String?) async -> CGImage? {
        guard let path = ShiyingCoverResolver.localFile(path) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let key = Self.key(for: url) else { return nil }
        if let image = memory.object(forKey: key as NSString) { return image.image }
        if let job = pending[key] { return await job.value }
        if failed.contains(key) { return nil }
        let destination = directory.appendingPathComponent(key + ".jpg")
        let job = Task { await self.loadOrGenerate(url, destination: destination) }
        pending[key] = job
        let image = await job.value
        pending[key] = nil
        if let image {
            memory.setObject(ImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        } else {
            if failed.count >= 128 { failed.removeAll() }
            failed.insert(key)
        }
        return image
    }

    private func acquire() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }

    private func loadOrGenerate(_ url: URL, destination: URL) async -> CGImage? {
        if let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        // 多页同时出现也最多两个解码任务；提取在后台完成，不占用主线程。
        await acquire()
        defer { release() }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            return image
        }
        guard url.isFileURL, url.scheme?.lowercased() == "file" else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let extracted: CGImage?
        if let image = try? await generator.image(at: .zero).image {
            extracted = image
        } else {
            // 精确零时刻失败时才解码真正的第一帧。不使用 -ss，不用 1 秒附近的帧冒充首帧。
            extracted = await ffmpegFirstFrame(fileURL: url)
        }
        guard let image = extracted else { return nil }
        let data = NSMutableData()
        if let writer = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            if CGImageDestinationFinalize(writer) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    try (data as Data).write(to: destination, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                } catch { /* 缓存不可写仍显示本次已提取的图片。 */ }
            }
        }
        return image
    }

    /// 只找 App 包内的 ffmpeg，不走 PATH，不打开远程地址。
    private static func bundledFFmpeg() -> URL? {
        let bundle = Bundle.main
        var candidates: [URL] = []
        if let auxiliary = bundle.url(forAuxiliaryExecutable: "ffmpeg") { candidates.append(auxiliary) }
        if let resource = bundle.url(forResource: "ffmpeg", withExtension: nil) { candidates.append(resource) }
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent("ffmpeg"))
            candidates.append(resources.appendingPathComponent("Tools/ffmpeg"))
        }
        if let executable = bundle.executableURL?.deletingLastPathComponent() {
            candidates.append(executable.appendingPathComponent("ffmpeg"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func ffmpegFirstFrame(fileURL url: URL) async -> CGImage? {
        guard url.isFileURL, url.scheme?.lowercased() == "file", FileManager.default.isReadableFile(atPath: url.path),
              let ffmpeg = Self.bundledFFmpeg() else { return nil }
        return await Task.detached(priority: .utility) { () -> CGImage? in
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-an", "-sn", "-dn",
                "-i", url.path,
                "-map", "0:v:0",
                "-frames:v", "1",
                "-vf", "scale=320:320:force_original_aspect_ratio=decrease",
                "-f", "image2pipe", "-vcodec", "png", "pipe:1"
            ]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            process.qualityOfService = .utility
            guard ShiyingThumbnailProcesses.start(process) else { return nil }
            defer { ShiyingThumbnailProcesses.finished(process) }
            let stderrDrain = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                _ = stderr.fileHandleForReading.readDataToEndOfFile()
                stderrDrain.signal()
            }
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
            let hardTimeout = DispatchWorkItem {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: hardTimeout)
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            hardTimeout.cancel()
            stderrDrain.wait()
            guard process.terminationStatus == 0, !data.isEmpty,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return image
        }.value
    }
}

struct ShiyingVideoCover: View {
    let path: String?
    var isPhoto = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(QQTheme.blue.opacity(0.16))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: isPhoto ? "photo" : "play.fill").font(.system(size: 19, weight: .medium)).foregroundStyle(QQTheme.blue)
            }
        }
        .frame(width: 104, height: 58.5)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.7))
        .accessibilityHidden(true)
        .task(id: path) {
            image = nil
            let thumbnail = await ShiyingThumbnailCache.shared.image(for: path)
            guard !Task.isCancelled else { return }
            image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}
