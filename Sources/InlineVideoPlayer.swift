import AVFoundation
import AVKit
import SwiftUI

/// 同一时刻只有一个卡片拥有播放器。generation 只增不减；
/// KVO、结束通知和进度回调必须同时匹配 generation、ownerID 与 AVPlayer 才能写状态。
@MainActor
final class ShiyingCardPlayback: ObservableObject {
    static let shared = ShiyingCardPlayback()

    @Published private(set) var ownerID: UUID?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var didPlayToEnd = false

    private var generation: UInt64 = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?

    init() {}

    func play(id: UUID, path: String) {
        guard let url = localPlayableURL(from: path) else { return }
        let generation = openSession(owner: id)

        isLoading = true
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.actionAtItemEnd = .pause
        avPlayer.preventsDisplaySleepDuringVideoPlayback = true
        player = avPlayer
        observe(player: avPlayer, item: item, generation: generation, owner: id)
        avPlayer.play()
    }

    func stop(id: UUID) {
        guard ownerID == id else { return }
        abandon()
    }

    func stopAll() {
        abandon()
    }

    private func openSession(owner: UUID) -> UInt64 {
        generation &+= 1
        let generation = generation
        tearDownObserversAndPlayer()
        ownerID = owner
        error = nil
        didPlayToEnd = false
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        progress = 0
        return generation
    }

    private func abandon() {
        generation &+= 1
        tearDownObserversAndPlayer()
        ownerID = nil
        error = nil
        isLoading = false
        isPlaying = false
        didPlayToEnd = false
        currentTime = 0
        duration = 0
        progress = 0
    }

    private func localPlayableURL(from path: String) -> URL? {
        guard let path = ShiyingCoverResolver.localFile(path),
              let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else {
            error = "视频文件已移动、为空或无法读取。"
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func observe(player avPlayer: AVPlayer, item: AVPlayerItem, generation: UInt64, owner: UUID) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            let itemDuration = item.duration
            Task { @MainActor [weak self] in
                guard let self, self.matches(generation: generation, owner: owner, player: avPlayer) else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    self.error = nil
                    self.publishDuration(itemDuration)
                case .failed:
                    self.isPlaying = false
                    self.isLoading = false
                    self.error = message ?? "无法播放该视频。"
                case .unknown:
                    self.isLoading = true
                @unknown default:
                    break
                }
            }
        }

        timeControlObservation = avPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.matches(generation: generation, owner: owner, player: player) else { return }
                switch status {
                case .playing:
                    self.isPlaying = true
                    self.isLoading = false
                    if self.didPlayToEnd {
                        self.didPlayToEnd = false
                    }
                case .paused:
                    self.isPlaying = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isPlaying = false
                    self.isLoading = true
                @unknown default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, self.matches(generation: generation, owner: owner, player: avPlayer) else { return }
                guard let ended = note.object as? AVPlayerItem, self.player?.currentItem === ended else { return }
                self.didPlayToEnd = true
                self.isPlaying = false
                self.isLoading = false
                if self.duration > 0 {
                    self.currentTime = self.duration
                    self.progress = 1
                }
                self.player?.pause()
            }
        }

        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.matches(generation: generation, owner: owner, player: avPlayer) else { return }
                self.isPlaying = false
                self.isLoading = false
                self.error = message ?? "播放中断，无法继续。"
                self.player?.pause()
            }
        }

        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self, self.matches(generation: generation, owner: owner, player: avPlayer) else { return }
                guard seconds.isFinite, seconds >= 0 else { return }
                self.currentTime = seconds
                if let itemDuration = self.player?.currentItem?.duration {
                    self.publishDuration(itemDuration)
                }
                if self.duration > 0 {
                    self.progress = min(1, max(0, seconds / self.duration))
                }
                if self.didPlayToEnd, self.duration > 0, seconds + 0.35 < self.duration {
                    self.didPlayToEnd = false
                }
            }
        }
    }

    private func publishDuration(_ time: CMTime) {
        guard time.isNumeric else { return }
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        progress = min(1, max(0, currentTime / duration))
    }

    private func matches(generation: UInt64, owner: UUID, player avPlayer: AVPlayer) -> Bool {
        self.generation == generation && ownerID == owner && player === avPlayer
    }

    private func tearDownObserversAndPlayer() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failedObserver {
            NotificationCenter.default.removeObserver(failedObserver)
            self.failedObserver = nil
        }
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

struct ShiyingInlinePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        apply(player, to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        apply(player, to: nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        let bound = coordinator.bound ?? nsView.player
        nsView.player?.pause()
        nsView.player = nil
        coordinator.bound = nil
        let playback = ShiyingCardPlayback.shared
        if let bound, playback.player === bound, let ownerID = playback.ownerID {
            playback.stop(id: ownerID)
        }
    }

    private func apply(_ player: AVPlayer, to view: AVPlayerView, coordinator: Coordinator) {
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsSharingServiceButton = false
        view.updatesNowPlayingInfoCenter = false
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        if view.player !== player {
            view.player = player
        }
        coordinator.bound = player
    }

    final class Coordinator {
        weak var bound: AVPlayer?
    }
}
