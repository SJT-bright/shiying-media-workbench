import SwiftUI

/// 手动刷新后的变化徽标：红色↑=上涨、蓝色↓=下降，数量写在箭头旁。
enum WorkStatisticsDeltaStyle {
    static let rise = Color(red: 0.88, green: 0.26, blue: 0.22)
    static let fall = Color(red: 0.10, green: 0.42, blue: 0.86)
    static let titles = ["like": "点赞", "comment": "评论", "collect": "收藏", "view": "浏览", "recommend": "推荐", "share": "转发"]
    static func title(_ key: String) -> String { titles[key] ?? key }
}

private struct WorkStatisticsDeltaChip: View {
    let delta: WorkStatisticsDelta
    var compact = true
    var metricTitle: String? = nil
    private var rising: Bool { delta.amount > 0 }
    private var amountText: String { String(abs(delta.amount)) }
    private var spoken: String {
        (rising ? "上涨 " : "下降 ") + (metricTitle ?? WorkStatisticsDeltaStyle.title(delta.key)) + " " + amountText
    }
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: rising ? "arrow.up" : "arrow.down")
                .font(.system(size: compact ? CGFloat(8) : CGFloat(9), weight: .bold))
            Text(amountText)
                .font(.system(size: compact ? CGFloat(9) : CGFloat(11), weight: .semibold)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(rising ? WorkStatisticsDeltaStyle.rise : WorkStatisticsDeltaStyle.fall)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .help("较上次更新" + spoken)
    }
}

struct WorkStatisticsControls: View {
    @EnvironmentObject var metrics: WorkStatisticsStore
    @EnvironmentObject var creator: CreatorStore
    let requests: [WorkStatisticsRequest]
    var skipped = 0
    var labels: [String: String] = [:]
    var body: some View {
        QQDepthSurface(radius: 16, padding: 12, accent: QQTheme.cyan) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("作品数据").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if metrics.isUpdating {
                        Button("停止更新") { metrics.cancel() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.orange))
                    } else {
                        Button { metrics.refresh(requests, skipped: skipped, labels: labels) } label: {
                            Label("更新作品数据（\(Set(requests.map(\.id)).count)）", systemImage: "arrow.clockwise")
                        }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                            .disabled(requests.isEmpty || creator.isScanning)
                    }
                }
                Text("按当前来源筛选手动更新作品数据。视频号分别显示喜欢与推荐；未公开的数据保留说明。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if skipped > 0 { Text("\(skipped)条记录缺少有效作品标识或暂不支持统计。") .font(.system(size: 11)).foregroundStyle(.secondary) }
                if metrics.isUpdating { Text(metrics.detail).font(.system(size: 12)).foregroundStyle(QQTheme.cyan) }
                if let notice = metrics.notice { Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                if let error = metrics.error { Text(error).font(.system(size: 12)).foregroundStyle(QQTheme.orange).textSelection(.enabled) }
            }
        }
        .sheet(isPresented: $metrics.showChangeSummary) {
            WorkStatisticsChangeSummary(changes: metrics.lastChanges, processedCount: metrics.processedCount, failedCount: metrics.failedCount)
        }
    }
}

struct WorkStatisticsChangeSummary: View {
    let changes: [WorkStatisticsChange]
    var processedCount: Int = 0
    var failedCount: Int = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("作品数据变化").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
            }
            Text((changes.isEmpty ? "本次更新\(processedCount)个作品，没有可比较的数值变化。" :
                    "本次更新\(processedCount)个作品，其中\(changes.count)个数据有变化（红色↑上涨、蓝色↓下降）。") +
                 (failedCount > 0 ? " \(failedCount)个更新失败，保留上次数据。" : ""))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(change.title?.isEmpty == false ? change.title! : "作品 " + change.id)
                                .font(.system(size: 12, weight: .semibold)).lineLimit(1).help(change.title ?? change.id)
                            HStack(spacing: 12) {
                                ForEach(change.deltas) { delta in
                                    let title = change.id.hasPrefix("wechat:") && delta.key == "like" ? "喜欢" : WorkStatisticsDeltaStyle.title(delta.key)
                                    HStack(spacing: 3) {
                                        Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                                        WorkStatisticsDeltaChip(delta: delta, compact: false, metricTitle: title)
                                    }
                                }
                            }
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .shiyingGlass(radius: 12)
                    }
                }.padding(.vertical, 2)
            }
        }
        .padding(20).frame(width: 470, height: 430)
    }
}

struct WorkStatisticsCard: View {
    var entry: WorkStatisticsEntry?
    var platform: MediaPlatform? = nil
    var historicalLikes: Int64? = nil
    var historicalCollects: Int64? = nil
    var change: WorkStatisticsChange? = nil
    @State private var showIssue = false
    private var snapshot: WorkStatistics? { entry?.value }
    private var oldLikes: Int64? { snapshot == nil ? historicalLikes.flatMap { $0 >= 0 ? $0 : nil } : nil }
    private var oldCollects: Int64? { snapshot == nil && platform != .wechat ? historicalCollects.flatMap { $0 >= 0 ? $0 : nil } : nil }
    private var hasHistorical: Bool { oldLikes != nil || oldCollects != nil }
    private func value(_ number: Int64?, key: String, views: Bool = false) -> String {
        if platform == .wechat && (key == "collect" || key == "view") { return "未公开" }
        if let number { return number.formatted(.number.locale(Locale(identifier: "zh_CN"))) }
        if let display = snapshot?.displayCounts?[key] { return display }
        if snapshot == nil { return "未更新" }
        return views ? "未公开" : "未返回"
    }
    private func metric(_ title: String, _ symbol: String, _ count: Int64?, key: String, views: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).frame(width: 12)
            Text(title)
            Spacer(minLength: 1)
            if let delta = change?.deltas.first(where: { $0.key == key }) {
                WorkStatisticsDeltaChip(delta: delta, metricTitle: title)
            }
            Text(value(count, key: key, views: views)).monospacedDigit().foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title + " " + value(count, key: key, views: views) +
                (change?.deltas.first(where: { $0.key == key }).map {
                    ($0.amount > 0 ? "，上涨 " : "，下降 ") + String(abs($0.amount))
                } ?? ""))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                metric(platform == .wechat ? "喜欢" : "点赞", "heart", snapshot?.likeCount ?? oldLikes, key: "like")
                metric("评论", "text.bubble", snapshot?.commentCount, key: "comment")
            }
            if platform == .wechat {
                HStack(spacing: 12) {
                    metric("推荐", "hand.thumbsup", snapshot?.recommendCount, key: "recommend")
                    metric("转发", "arrowshape.turn.up.right", snapshot?.shareCount, key: "share")
                }
            }
            HStack(spacing: 12) {
                metric("收藏", "star", snapshot?.collectCount ?? oldCollects, key: "collect", views: platform == .wechat)
                metric("浏览", "eye", snapshot?.viewCount, key: "view", views: true).help(snapshot?.viewsNote ?? "手动更新后显示平台提供的数据。")
            }
            if let snapshot {
                Text("更新于 " + Date(timeIntervalSince1970: TimeInterval(snapshot.observedAt)).formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help(snapshot.source + "。" + (snapshot.metricsNote ?? ""))
            } else if hasHistorical {
                Text("历史采集值 · 尚未成功刷新").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let issue = entry?.issue {
                HStack {
                    Text(snapshot == nil && !hasHistorical ? "数据更新失败" : "本次失败，保留上次数据").font(.system(size: 10)).foregroundStyle(QQTheme.orange)
                    Spacer()
                    Button("详情") { showIssue = true }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(QQTheme.orange)
                        .accessibilityLabel("作品数据更新失败详情")
                        .popover(isPresented: $showIssue) { Text(issue).font(.system(size: 12)).textSelection(.enabled).padding(16).frame(width: 370) }
                }.help(issue)
            }
        }.padding(.vertical, 5)
    }
}
