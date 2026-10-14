import SwiftUI
import AppKit
import AVFoundation

/// 保存的视频只呈现观看和查找文件所需的信息。
struct ShiyingVideoTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback = ShiyingCardPlayback.shared
    @State private var ownerID = UUID()
    @State private var expanded = false

    let title: String
    let author: String
    var description: String? = nil
    let path: String?
    var imagePaths: [String]? = nil
    var coverPath: String? = nil
    var source: MediaSource = .unknown
    var problem: String? = nil
    var statistics: WorkStatisticsEntry? = nil
    var historicalLikes: Int64? = nil
    var historicalCollects: Int64? = nil
    var statisticsChange: WorkStatisticsChange? = nil
    var play: () -> Void
    var reveal: () -> Void

    private var isPhoto: Bool { imagePaths != nil }
    private var albumBadge: String? {
        guard isPhoto, let count = imagePaths?.count, count > 1 else { return nil }
        return "图文 · \(count) 张图片"
    }
    private var platformCoverURL: String? {
        guard !isPhoto else { return nil }
        return statistics?.value?.coverURL
    }

    private var exists: Bool {
        isPhoto ? (imagePaths ?? []).contains { ShiyingCoverResolver.localFile($0) != nil }
            : ShiyingCoverResolver.localFile(path) != nil
    }

    private var revealExists: Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private var unavailable: String { "文件已移动或暂不可用" }

    private var showsInline: Bool {
        expanded && !isPhoto && playback.ownerID == ownerID
    }

    var body: some View {
        let content = VideoCardContent(title: title, description: description)
        QQDepthSurface(radius: 17, padding: 12, accent: QQTheme.blue) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    coverColumn
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            ScrollView(.horizontal, showsIndicators: true) {
                                Text(author.isEmpty ? "未知博主" : author)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            }
                            .frame(maxWidth: .infinity).frame(height: 18).clipped()
                            .help(author.isEmpty ? "未知博主" : author)
                            .accessibilityLabel("作者名称，可横向滚动")
                            Button(action: reveal) {
                                Image(systemName: "folder")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(QQGhostPressStyle(tint: QQTheme.cyan, radius: 6, glass: true))
                            .disabled(!revealExists)
                            .help(revealExists ? "在访达中显示" : unavailable)
                            .accessibilityLabel("在访达中显示作品")
                        }
                        Label(source.title, systemImage: source.symbol)
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(QQTheme.cyan)
                            .padding(.horizontal, 6).padding(.vertical, 2).shiyingGlass(radius: 6)
                            .accessibilityLabel("作品来源：" + source.title)
                        if let albumBadge {
                            Text(albumBadge)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showsInline {
                    inlinePlayer
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                ShiyingScrollableCardText(text: content.title, size: 14, weight: .semibold, visibleLines: 1)
                    .accessibilityLabel("作品标题")
                    .help(content.title)
                if content.description.isEmpty {
                    Text("暂无作品简介").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ShiyingScrollableCardText(text: content.description, size: 12, weight: .regular, visibleLines: 3)
                        .foregroundStyle(.secondary).accessibilityLabel("作品简介")
                }
                if !content.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(content.tags, id: \.self) { tag in
                                Text("#" + tag).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(QQTheme.blue).lineLimit(1)
                            }
                        }
                    }
                    .frame(height: 14).clipped()
                }
                WorkStatisticsCard(entry: statistics, platform: source.platform, historicalLikes: historicalLikes, historicalCollects: historicalCollects, change: statisticsChange)
                if let problem, !problem.isEmpty {
                    Text(problem).font(.system(size: 11)).foregroundStyle(QQTheme.orange).lineLimit(2)
                } else if !exists {
                    Text(unavailable).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear { playback.stop(id: ownerID) }
        .onChange(of: playback.ownerID) { _, owner in
            if owner != ownerID { withAnimation(playerAnimation) { expanded = false } }
        }
        .onChange(of: path) { _, _ in playback.stop(id: ownerID); expanded = false }
    }

    @ViewBuilder
    private var coverColumn: some View {
        if isPhoto {
            Button(action: play) {
                coverImage
            }
            .buttonStyle(.plain)
            .disabled(!exists)
            .accessibilityLabel(exists ? "查看图片" : "无法查看，" + unavailable)
            .help(exists ? "查看图片" : unavailable)
        } else {
            ZStack {
                coverImage
                    .accessibilityHidden(true)
                Button(action: togglePlayback) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!exists && !showsInline)
                .accessibilityLabel(showsInline ? "收回卡片内播放" : (exists ? "在卡片内播放视频" : "无法播放，" + unavailable))
                .help(showsInline ? "再次点击停止并收回" : (exists ? "点击展开并播放" : unavailable))
            }
            .frame(width: 104, height: 58.5)
        }
    }

    @ViewBuilder private var coverImage: some View {
        if let url = platformCoverURL {
            ShiyingPlatformCover(url: url) {
                ShiyingVideoCover(path: coverPath ?? (isPhoto ? imagePaths?.first : path), isPhoto: isPhoto)
            }
            .frame(width: 104, height: 58.5)
            .clipped()
        } else {
            ShiyingVideoCover(path: coverPath ?? (isPhoto ? imagePaths?.first : path), isPhoto: isPhoto)
                .frame(width: 104, height: 58.5)
                .clipped()
        }
    }

    private var inlinePlayer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let player = playback.player {
                ShiyingInlinePlayerView(player: player)
                    .frame(height: 232)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("卡片内视频播放器")
                ShiyingPlaybackControls(playback: playback, ownerID: ownerID)
            }
            if let error = playback.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(QQTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("播放失败：" + error)
            }
        }
    }

    private var playerAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.28)
    }

    private func togglePlayback() {
        if showsInline {
            closePlayback()
            return
        }
        guard !isPhoto, let path, exists else { return }
        withAnimation(playerAnimation) {
            playback.play(id: ownerID, path: path)
            expanded = true
        }
    }

    private func closePlayback() {
        withAnimation(playerAnimation) { playback.stop(id: ownerID); expanded = false }
    }
}

struct ShiyingSourceFilter: View {
    @Binding var selection: MediaSource?
    var counts: [MediaSource: Int]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                choice(nil, title: "全部来源", count: counts.values.reduce(0, +))
                ForEach(MediaSource.allCases.filter { $0 != .unknown || (counts[$0] ?? 0) > 0 }) { source in
                    choice(source, title: source.title, count: counts[source] ?? 0)
                }
            }.padding(.vertical, 2)
        }
        .accessibilityLabel("按作品来源筛选")
    }
    private func choice(_ source: MediaSource?, title: String, count: Int) -> some View {
        Button { selection = source } label: { Text("\(title) · \(count)") }
            .buttonStyle(QQSoftButtonStyle(tint: selection == source ? QQTheme.cyan : QQTheme.slate))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(selection == source ? QQTheme.cyan.opacity(0.7) : .clear, lineWidth: 1) }
            .accessibilityLabel("筛选" + title + "，\(count)个作品")
            .accessibilityAddTraits(selection == source ? [.isSelected] : [])
    }
}

struct ShiyingSourceHeading: View {
    let source: MediaSource
    let count: Int
    var body: some View {
        HStack {
            Label(source.title, systemImage: source.symbol).font(.system(size: 14, weight: .semibold))
            Text("\(count) 个作品").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }.padding(.top, 6).accessibilityElement(children: .combine)
    }
}

/// 用同一份排版测量可见行高，滚动层保留全文；短内容按实际行数收紧。
private struct ShiyingScrollableCardText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let visibleLines: Int

    private var fullText: some View {
        Text(text).font(.system(size: size, weight: weight)).lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        Text(text).font(.system(size: size, weight: weight)).lineSpacing(3)
            .lineLimit(visibleLines)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden().accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                ScrollView(.vertical) { fullText.textSelection(.enabled) }
                    .clipped()
            }
    }
}
