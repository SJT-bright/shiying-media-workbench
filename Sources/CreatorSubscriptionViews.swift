import SwiftUI

struct ShiyingCreatorSubscriptionPanel: View {
    let blocked: Bool
    @EnvironmentObject private var subscriptions: CreatorSubscriptionStore
    @EnvironmentObject private var creator: CreatorStore
    @EnvironmentObject private var batch: BatchStore
    @EnvironmentObject private var store: Store
    @State private var removing: CreatorSubscription?
    @State private var displayedPlatform: MediaPlatform = .douyin
    @Environment(\.dismiss) private var dismiss

    private var available: Bool { displayedPlatform != .wechat }
    private var items: [CreatorSubscription] { subscriptions.items(for: displayedPlatform) }
    private var subscribeDisabled: Bool {
        blocked || subscriptions.isUpdating || !subscriptions.canWrite || !available || displayedPlatform != creator.platform || creator.scannedCreatorID == nil || creator.creatorName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(QQTheme.cyan)
                Text("博主订阅").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button {
                    subscriptions.subscribe(creator: creator, batch: batch, store: store)
                } label: {
                    Label(subscriptions.current(creator) == nil ? "订阅当前博主" : "保存订阅设置", systemImage: "plus.circle")
                }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan)).disabled(subscribeDisabled)
            }
            HStack(spacing: 8) {
                ForEach(MediaPlatform.allCases) { platform in
                    Button { displayedPlatform = platform; subscriptions.message = nil } label: {
                        Label(platform.title, systemImage: platform.symbol).frame(maxWidth: .infinity)
                    }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan, selected: displayedPlatform == platform))
                        .accessibilityLabel("查看\(platform.title)订阅")
                        .accessibilityValue(displayedPlatform == platform ? "已选中" : "未选中")
                }
            }
            Text(available ? "点击更新，自动下载仓库里缺少的视频。订阅与保存设置会长期保留。" : "视频号当前仅支持单条分享，尚未开放博主主页订阅。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 28)).foregroundStyle(QQTheme.cyan)
                            Text("还没有\(displayedPlatform.title)订阅").font(.system(size: 14, weight: .medium))
                            if available { Text("在主页采集取得博主名称后，回来订阅即可。")
                                .font(.system(size: 12)).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, minHeight: 150)
                    }
                    ForEach(items) { item in subscriptionRow(item) }
                }.padding(.vertical, 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let issue = subscriptions.issue {
                Text(issue).font(.system(size: 12)).foregroundStyle(QQTheme.orange).textSelection(.enabled)
            } else if let message = subscriptions.message {
                Text(message).font(.system(size: 12)).foregroundStyle(subscriptions.isUpdating ? QQTheme.cyan : .secondary)
            }
            HStack {
                Text("\(items.count) 位已订阅博主").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(QQSoftButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 700, idealWidth: 820, maxWidth: 980, minHeight: 480, idealHeight: 620, maxHeight: 800)
        .background { ShiyingWallpaper() }
        .onAppear { displayedPlatform = creator.platform }
        .confirmationDialog("取消订阅「\(removing?.name ?? "")」？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("取消订阅", role: .destructive) {
                if let item = removing { subscriptions.remove(item.id) }
                removing = nil
            }
            Button("保留订阅", role: .cancel) { removing = nil }
        } message: { Text("已下载的作品、文件和目录会保留。") }
    }

    private func subscriptionRow(_ item: CreatorSubscription) -> some View {
        let updating = subscriptions.updatingID == item.id
        let target = batch.collections.first { $0.id == item.collectionID }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    creator.selectPlatform(item.platform)
                    creator.urlText = item.homepage
                    batch.selectCollection(item.collectionID)
                    if let path = target?.path { store.folder = path }
                    batch.quality = Quality(rawValue: item.quality) ?? .original
                    batch.includeAudio = item.includeAudio
                    dismiss()
                } label: {
                    Label(item.name, systemImage: "person.crop.circle")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                    .disabled(blocked || subscriptions.isUpdating)
                    .accessibilityLabel("选择订阅博主\(item.name)")
                Text("保存到：\(target?.name ?? "目录不可用") · \(Quality(rawValue: item.quality)?.title ?? "最高画质")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Text(updating ? "正在检查新作品…" : subscriptions.resultText(item, batch: batch))
                    .font(.system(size: 11)).foregroundStyle(item.lastScanComplete ? .secondary : QQTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = item.lastCheckedAt {
                    Text("最近检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if updating {
                ProgressView().controlSize(.small)
                Button("取消") { subscriptions.cancel(creator: creator) }.buttonStyle(QQSoftButtonStyle())
            } else {
                Button {
                    subscriptions.update(item, creator: creator, batch: batch, store: store)
                } label: { Label("更新", systemImage: "arrow.clockwise") }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.mint))
                    .disabled(blocked || subscriptions.isUpdating || !subscriptions.canWrite)
                    .accessibilityLabel("更新订阅博主\(item.name)")
                Button { removing = item } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(QQSoftButtonStyle(tint: .secondary))
                    .disabled(blocked || subscriptions.isUpdating || !subscriptions.canWrite)
                    .accessibilityLabel("取消订阅博主\(item.name)")
            }
        }.padding(12).shiyingGlass(radius: 14, inset: true)
    }
}
