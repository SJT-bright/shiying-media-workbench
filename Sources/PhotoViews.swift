import SwiftUI
import AppKit
import ImageIO

/// Reads local preview bytes into memory; never creates a persistent thumbnail or network cache.
private struct ShiyingLocalPhoto: View {
    let path: String?
    var maxPixels = 320
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(.secondary) }
        }
        .task(id: path) {
            image = nil
            let path = path, maxPixels = maxPixels
            let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let path, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

struct ShiyingPhotoPreview: View {
    let title: String
    let author: String
    let images: [PhotoPreview]
    let paths: [String]
    let onCopy: (Int) -> Void
    let onView: (Int) -> Void
    var body: some View {
        QQDepthSurface(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(author).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    QQPill(text: "图文 · \(images.count) 张图片", tint: QQTheme.cyan, symbol: "photo.on.rectangle")
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, photo in
                            VStack(spacing: 6) {
                                Button { onView(index) } label: {
                                    ShiyingLocalPhoto(path: paths.indices.contains(index) ? paths[index] : nil)
                                        .frame(width: 154, height: 160).shiyingGlass(radius: 12, inset: true)
                                }.buttonStyle(.plain).disabled(!paths.indices.contains(index))
                                .accessibilityLabel("查看第 \(index + 1) 张图片，可右键复制")
                                .contextMenu {
                                    Button("复制图片") { onCopy(index) }.disabled(!paths.indices.contains(index))
                                }
                                Text("第 \(index + 1) 张" + (photo.width.map { " · \($0) × \(photo.height ?? 0)" } ?? ""))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.bottom, 4)
                }
                Text("图片可右键复制。确认保存才放入所选文件夹；取消保存会清理本次临时图片。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ShiyingAlbumViewer: View {
    let title: String
    let paths: [String]
    let onConfirm: (() -> Void)?
    let onDiscard: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int
    @State private var copyNotice: String?
    private var path: String? { paths.indices.contains(selected) ? paths[selected] : nil }
    init(title: String, paths: [String], initialIndex: Int = 0, onConfirm: (() -> Void)? = nil, onDiscard: (() -> Void)? = nil) {
        self.title = title; self.paths = paths; self.onConfirm = onConfirm; self.onDiscard = onDiscard
        _selected = State(initialValue: max(0, min(initialIndex, paths.count - 1)))
    }
    private func copy(_ index: Int) {
        guard paths.indices.contains(index) else { return }
        do { try ShiyingPhotoClipboard.copy(path: paths[index]); copyNotice = "第 \(index + 1) 张图片已复制，可直接粘贴。" }
        catch { copyNotice = error.localizedDescription }
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label(title, systemImage: "photo.on.rectangle").font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Spacer()
                Text(paths.isEmpty ? "没有图片" : "\(selected + 1) / \(paths.count)").font(.system(size: 13)).monospacedDigit()
                Button("关闭") { dismiss() }.buttonStyle(QQSoftButtonStyle()).keyboardShortcut(.cancelAction)
            }
            ShiyingLocalPhoto(path: path, maxPixels: 4096)
                .frame(maxWidth: .infinity, maxHeight: .infinity).shiyingGlass(radius: 16, inset: true)
                .accessibilityLabel("当前第 \(selected + 1) 张图片，可右键复制")
                .contextMenu { Button("复制图片") { copy(selected) }.disabled(path == nil) }
            HStack(spacing: 12) {
                Button { selected -= 1 } label: { Label("上一张", systemImage: "chevron.left") }
                    .buttonStyle(QQSoftButtonStyle()).disabled(selected <= 0).keyboardShortcut(.leftArrow, modifiers: [])
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                            Button { selected = index } label: {
                                VStack(spacing: 3) {
                                    ShiyingLocalPhoto(path: path).frame(width: 104, height: 58.5)
                                    Text("\(index + 1)").font(.system(size: 10))
                                }.padding(4).shiyingGlass(radius: 10, tint: selected == index ? QQTheme.cyan.opacity(0.2) : .clear)
                            }.buttonStyle(.plain).accessibilityLabel("查看第 \(index + 1) 张图片")
                                .contextMenu { Button("复制图片") { copy(index) } }
                        }
                    }
                }
                Button { selected += 1 } label: { Label("下一张", systemImage: "chevron.right") }
                    .buttonStyle(QQSoftButtonStyle()).disabled(selected >= paths.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
            }
            HStack {
                Text(copyNotice ?? (onConfirm == nil ? "右键图片即可复制" : "临时图片：确认保存才入库，取消会清理图片"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("复制图片") { copy(selected) }.buttonStyle(QQSoftButtonStyle()).disabled(path == nil)
                    .keyboardShortcut("c", modifiers: .command)
                if let onDiscard { Button("取消保存", action: onDiscard).buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose)) }
                if let onConfirm { Button("确认保存", action: onConfirm).buttonStyle(QQDepthButtonStyle()) }
            }
        }.padding(20).frame(width: 800, height: 660).background { ShiyingWallpaper() }
    }
}
