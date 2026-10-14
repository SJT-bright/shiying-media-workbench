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
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var isScrubbing = false
    @Published private(set) var isSeeking = false
    static let playbackRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    private var generation: UInt64 = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var seekRevision: UInt64 = 0
    private var wantsPlayback = false

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
        wantsPlayback = true
        observe(player: avPlayer, item: item, generation: generation, owner: id)
        avPlayer.playImmediately(atRate: playbackRate)
    }

    func togglePause(id: UUID) {
        guard ownerID == id, let player, player.currentItem?.status == .readyToPlay, !isScrubbing else { return }
        let active = isSeeking ? wantsPlayback : player.timeControlStatus != .paused
        if active && !didPlayToEnd {
            wantsPlayback = false
            player.pause()
            isPlaying = false
        } else {
            wantsPlayback = true
            if didPlayToEnd || (duration > 0 && currentTime >= duration - 0.05) {
                seek(id: id, seconds: 0, resume: true)
            } else if !isSeeking {
                player.playImmediately(atRate: playbackRate)
            }
        }
    }

    func setRate(id: UUID, rate: Float) {
        guard ownerID == id, let player, Self.playbackRates.contains(rate) else { return }
        playbackRate = rate
        player.defaultRate = rate
        if !isScrubbing && !isSeeking && !didPlayToEnd && player.timeControlStatus != .paused {
            wantsPlayback = true
            player.playImmediately(atRate: rate)
        }
    }

    func beginScrubbing(id: UUID) {
        guard ownerID == id, let player, duration > 0, player.currentItem?.status == .readyToPlay else { return }
        if !isSeeking { wantsPlayback = player.timeControlStatus != .paused }
        isScrubbing = true
        player.pause()
        isPlaying = false
    }

    func seek(id: UUID, seconds: Double, resume: Bool? = nil) {
        guard ownerID == id, let player, player.currentItem?.status == .readyToPlay,
              duration > 0, seconds.isFinite else { return }
        let target = min(duration, max(0, seconds))
        if let resume { wantsPlayback = resume }
        isScrubbing = false
        isSeeking = true
        isPlaying = false
        didPlayToEnd = false
        currentTime = target
        progress = target / duration
        seekRevision &+= 1
        let revision = seekRevision, session = generation
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.matches(generation: session, owner: id, player: player),
                      self.seekRevision == revision else { return }
                self.isSeeking = false
                if !finished { return }
                let actual = player.currentTime().seconds
                if actual.isFinite {
                    self.currentTime = min(self.duration, max(0, actual))
                    self.progress = self.currentTime / self.duration
                }
                if self.wantsPlayback && !self.isScrubbing {
                    player.playImmediately(atRate: self.playbackRate)
                }
            }
        }
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
        resetControls()
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
        resetControls()
    }

    private func resetControls() {
        seekRevision &+= 1
        wantsPlayback = false
        playbackRate = 1
        isScrubbing = false
        isSeeking = false
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
                guard player.timeControlStatus == status else { return }
                switch status {
                case .playing:
                    self.wantsPlayback = true
                    self.isPlaying = true
                    self.isLoading = false
                    if self.didPlayToEnd {
                        self.didPlayToEnd = false
                    }
                case .paused:
                    self.isPlaying = false
                    if !self.isScrubbing && !self.isSeeking { self.wantsPlayback = false }
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
                self.wantsPlayback = false
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
                self.wantsPlayback = false
                self.player?.pause()
            }
        }

        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self, self.matches(generation: generation, owner: owner, player: avPlayer) else { return }
                guard !self.isScrubbing, !self.isSeeking else { return }
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
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

struct ShiyingInlinePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ShiyingPlayerSurface {
        let view = ShiyingPlayerSurface()
        apply(player, to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: ShiyingPlayerSurface, context: Context) {
        apply(player, to: nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: ShiyingPlayerSurface, coordinator: Coordinator) {
        let bound = coordinator.bound ?? nsView.videoLayer.player
        nsView.videoLayer.player?.pause()
        nsView.videoLayer.player = nil
        coordinator.bound = nil
        let playback = ShiyingCardPlayback.shared
        if let bound, playback.player === bound, let ownerID = playback.ownerID {
            playback.stop(id: ownerID)
        }
    }

    private func apply(_ player: AVPlayer, to view: ShiyingPlayerSurface, coordinator: Coordinator) {
        if view.videoLayer.player !== player {
            view.videoLayer.player = player
        }
        coordinator.bound = player
    }

    final class Coordinator {
        weak var bound: AVPlayer?
    }
}

/// The picture layer does not install a second set of controls or change playback state.
final class ShiyingPlayerSurface: NSView {
    let videoLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = videoLayer
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Controls stay below the picture, including when the pointer leaves the player.
struct ShiyingPlaybackControls: View {
    @ObservedObject var playback: ShiyingCardPlayback
    let ownerID: UUID
    @State private var draftTime: Double = 0
    @State private var isDragging = false

    private var ready: Bool { playback.ownerID == ownerID && playback.duration > 0 && playback.error == nil }
    private var shownTime: Double { isDragging ? draftTime : playback.currentTime }

    var body: some View {
        VStack(spacing: 5) {
            timeline
            HStack(spacing: 8) {
                Button { playback.togglePause(id: ownerID) } label: {
                    Image(systemName: playback.didPlayToEnd ? "arrow.counterclockwise" : playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!ready || playback.isScrubbing)
                .accessibilityLabel(playback.didPlayToEnd ? "重新播放视频" : playback.isPlaying ? "暂停视频" : "继续播放视频")
                Text(Self.timeText(shownTime) + " / " + Self.timeText(playback.duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).monospacedDigit()
                    .accessibilityLabel("播放时间 " + Self.timeText(shownTime) + "，总时长 " + Self.timeText(playback.duration))
                Spacer(minLength: 0)
                if playback.isLoading || playback.isSeeking {
                    ProgressView().controlSize(.mini).accessibilityLabel("正在加载播放位置")
                }
                Menu {
                    ForEach(ShiyingCardPlayback.playbackRates, id: \.self) { rate in
                        Button { playback.setRate(id: ownerID, rate: rate) } label: {
                            if playback.playbackRate == rate { Label(Self.rateText(rate), systemImage: "checkmark") }
                            else { Text(Self.rateText(rate)) }
                        }
                    }
                } label: {
                    Text(Self.rateText(playback.playbackRate)).font(.system(size: 11, weight: .semibold))
                        .frame(minWidth: 30, minHeight: 22)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!ready)
                .accessibilityLabel("播放倍速 " + Self.rateText(playback.playbackRate))
                .help("选择播放速度")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 7)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let track = max(1, geometry.size.width - 12)
            let fraction = playback.duration > 0 ? min(1, max(0, shownTime / playback.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 4).padding(.horizontal, 6)
                Capsule().fill(.cyan).frame(width: track * fraction, height: 4).offset(x: 6)
                Circle().fill(.white).frame(width: 12, height: 12).offset(x: track * fraction)
            }
            .frame(height: 22).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard ready else { return }
                    if !isDragging {
                        isDragging = true
                        playback.beginScrubbing(id: ownerID)
                    }
                    draftTime = min(1, max(0, (value.location.x - 6) / track)) * playback.duration
                }
                .onEnded { value in
                    guard ready else { isDragging = false; return }
                    draftTime = min(1, max(0, (value.location.x - 6) / track)) * playback.duration
                    isDragging = false
                    playback.seek(id: ownerID, seconds: draftTime)
                })
        }
        .frame(height: 22)
        .opacity(ready ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("视频播放进度")
        .accessibilityValue(Self.timeText(shownTime) + "，共 " + Self.timeText(playback.duration))
        .accessibilityAdjustableAction { direction in
            guard ready else { return }
            let step = min(10, max(1, playback.duration / 100))
            switch direction {
            case .increment: playback.seek(id: ownerID, seconds: playback.currentTime + step)
            case .decrement: playback.seek(id: ownerID, seconds: playback.currentTime - step)
            @unknown default: break
            }
        }
        .help("点击或拖动跳转到对应时间")
    }

    static func rateText(_ rate: Float) -> String { String(format: "%g×", rate) }
    static func timeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return "0:00" }
        let seconds = Int(value)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
