import SwiftUI

struct ShiyingFolderPicker: View {
    let title: String
    let initialPath: String
    let collections: [StudyCollection]
    let libraryRoot: String
    let busy: Bool
    let confirm: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var location: String
    @State private var pathInput: String
    @State private var folders: [URL] = []
    @State private var search = ""
    @State private var issue: String?
    @State private var loading = false
    @State private var listingFailed = false
    @State private var creating = false
    @State private var newName = ""
    @State private var request = UUID()

    init(title: String, initialPath: String, collections: [StudyCollection], libraryRoot: String,
         busy: Bool, confirm: @escaping (String) -> Bool) {
        self.title = title; self.initialPath = initialPath; self.collections = collections
        self.libraryRoot = libraryRoot; self.busy = busy; self.confirm = confirm
        _location = State(initialValue: initialPath); _pathInput = State(initialValue: initialPath)
    }

    private var shown: [URL] {
        folders.filter { search.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(search) }
    }
    private var selectable: Bool { !loading && !busy && (try? FolderBrowser.directory(location, writable: true)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                QQIconTile(symbol: "folder.fill", size: 36, gradient: QQTheme.warm)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Text("在拾影里切换目录，确认后用于接下来的下载。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 14) {
                sidebar.frame(width: 185)
                VStack(alignment: .leading, spacing: 10) {
                    navigation
                    TextField("筛选当前目录下的文件夹", text: $search)
                        .textFieldStyle(ShiyingGlassFieldStyle()).accessibilityLabel("筛选文件夹")
                    directoryList
                    if creating { creationForm }
                }
            }.frame(maxHeight: .infinity)
            if let issue {
                Text(issue).font(.system(size: 12)).foregroundStyle(QQTheme.orange)
                    .textSelection(.enabled).lineLimit(3)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("即将保存到").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(short(location)).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle).help(location)
                }
                Spacer(minLength: 8)
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(QQSoftButtonStyle())
                Button("保存到这里") { accept() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan, compact: true))
                    .disabled(!selectable)
            }
        }
        .padding(22).frame(width: 760, height: 570)
        .background { ShiyingWallpaper() }
        .task { navigate(initialPath) }
        .onDisappear { request = UUID() }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text("常用位置").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                shortcut("当前保存位置", symbol: "arrow.down.to.line", path: initialPath)
                shortcut("学习资料", symbol: "folder.fill", path: libraryRoot)
                let home = FileManager.default.homeDirectoryForCurrentUser
                shortcut("下载", symbol: "arrow.down.circle", path: home.appendingPathComponent("Downloads").path)
                shortcut("桌面", symbol: "desktopcomputer", path: home.appendingPathComponent("Desktop").path)
                shortcut("个人文件夹", symbol: "house", path: home.path)
                shortcut("磁盘与外置设备", symbol: "externaldrive", path: "/Volumes")
                Divider().padding(.vertical, 6)
                Text("学习文件夹").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if collections.isEmpty {
                    Text("还没有学习文件夹").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(collections) { folder in
                    let names = CollectionOrganization.ancestors(of: folder.id, in: collections).map(\.name)
                    shortcut(names.joined(separator: " / "), symbol: "folder", path: folder.path)
                }
            }.padding(10)
        }.shiyingGlass(radius: 16, inset: true)
    }

    private func shortcut(_ name: String, symbol: String, path: String) -> some View {
        Button { navigate(path) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(QQTheme.cyan).frame(width: 18)
                Text(name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 12)).padding(8)
                .shiyingGlass(radius: 10, tint: location == path ? QQTheme.cyan.opacity(0.16) : .clear)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(path).accessibilityLabel("打开" + name)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button { navigate(URL(fileURLWithPath: location).deletingLastPathComponent().path) } label: {
                    Label("上一级", systemImage: "arrow.up")
                }.buttonStyle(QQSoftButtonStyle()).disabled(location == "/")
                Button { navigate(location) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QQSoftButtonStyle()).accessibilityLabel("刷新文件夹")
                Spacer()
                Button { creating.toggle(); newName = "" } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan)).disabled(!selectable)
            }
            HStack(spacing: 8) {
                TextField("目录路径", text: $pathInput).textFieldStyle(ShiyingGlassFieldStyle())
                    .accessibilityLabel("目录路径").onSubmit { navigate(pathInput) }
                Button("前往") { navigate(pathInput) }.buttonStyle(QQSoftButtonStyle())
            }
        }
    }

    private var directoryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if loading {
                    ProgressView("正在读取文件夹…").padding(20)
                } else if listingFailed {
                    Text("无法显示子文件夹，请返回上一级或输入其他目录路径。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
                } else if shown.isEmpty {
                    Text(search.isEmpty ? "这里没有子文件夹，可直接保存到当前目录。" : "没有匹配的子文件夹。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
                } else {
                    ForEach(shown, id: \.path) { folder in
                        Button { navigate(folder.path) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").foregroundStyle(QQTheme.orange)
                                Text(folder.lastPathComponent).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.font(.system(size: 13)).padding(12).contentShape(Rectangle())
                                .shiyingGlass(radius: 12)
                        }.buttonStyle(.plain).accessibilityLabel("进入文件夹：" + folder.lastPathComponent)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).shiyingGlass(radius: 16, inset: true)
    }

    private var creationForm: some View {
        HStack(spacing: 8) {
            TextField("新文件夹名称", text: $newName).textFieldStyle(ShiyingGlassFieldStyle())
                .accessibilityLabel("新文件夹名称").onSubmit { create() }
            Button("创建并进入") { create() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectable)
        }
    }

    private func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func navigate(_ path: String) {
        do {
            let url = try FolderBrowser.directory(path)
            let token = UUID(); request = token
            location = url.path; pathInput = url.path; search = ""; issue = nil; loading = true; listingFailed = false
            folders = []; creating = false
            Task {
                let result = await Task.detached(priority: .userInitiated) { Result { try FolderBrowser.children(of: url.path) } }.value
                guard request == token else { return }
                loading = false
                switch result {
                case .success(let children):
                    folders = children
                    if !FileManager.default.isWritableFile(atPath: url.path) { issue = "这个文件夹不可写，请选择其他保存位置。" }
                case .failure(let error): listingFailed = true; issue = "无法读取这个文件夹：\(error.localizedDescription)"
                }
            }
        } catch { issue = error.localizedDescription }
    }

    private func create() {
        guard selectable else { return }
        do { let folder = try FolderBrowser.create(name: newName, in: location); newName = ""; navigate(folder.path) }
        catch { issue = error.localizedDescription }
    }

    private func accept() {
        guard !busy, !loading else { return }
        do {
            let target = try FolderBrowser.directory(location, writable: true)
            if confirm(target.path) { dismiss() }
            else { issue = "当前有下载任务正在处理，请结束后再更换目录。" }
        } catch { issue = error.localizedDescription }
    }
}
