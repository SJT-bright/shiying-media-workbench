import SwiftUI
import UniformTypeIdentifiers

struct ShiyingStudyLibraryView: View {
    @EnvironmentObject var batch: BatchStore
    @EnvironmentObject var store: Store
    @EnvironmentObject var metrics: WorkStatisticsStore
    @State private var location: UUID?
    @State private var creating = false
    @State private var creationNotes = ""
    @State private var dialog: CollectionDialog?
    @State private var shown = 60
    @State private var source: MediaSource? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let folders = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 14)]
    private let videos = [GridItem(.adaptive(minimum: 222, maximum: 300), spacing: 12, alignment: .top)]
    private var busy: Bool { batch.isRunning || store.busy }
    private var current: StudyCollection? { batch.collections.first { $0.id == location } }
    private var coverCandidates: [ShiyingCoverCandidate] {
        batch.items.filter { $0.status == .completed }.map { ShiyingCoverCandidate(link: $0.link, videoID: $0.videoID, path: $0.path, imagePaths: $0.imagePaths) }
    }

    private var statisticsItems: [BatchItem] {
        batch.items.filter { item in item.status == .completed && (source == nil || source == MediaSource.from(link: item.link)) && (location == nil || CollectionOrganization.ancestors(of: item.collectionID, in: batch.collections).contains { $0.id == location }) }
    }
    private var statisticsRequests: [WorkStatisticsRequest] {
        statisticsItems.compactMap { WorkStatisticsRepository.request(link: $0.link, videoID: $0.videoID, homepage: $0.creatorSourceURL) }
    }
    private var statisticsLabels: [String: String] {
        statisticsItems.reduce(into: [:]) { labels, item in
            if let id = WorkStatisticsRepository.id(link: item.link, videoID: item.videoID) { labels[id] = item.title }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                contents.id("library-top")
                    .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, location == nil ? 26 : 88)
            }
            .overlay(alignment: .bottomTrailing) {
                if current != nil {
                    Button(action: goBack) { Label("返回上一级", systemImage: "arrow.turn.up.left") }
                        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                        .padding(.trailing, 26).padding(.bottom, 22)
                        .accessibilityLabel("固定返回上一级")
                }
            }
            .onChange(of: location) { _, _ in
                if reduceMotion { proxy.scrollTo("library-top", anchor: .top) }
                else { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("library-top", anchor: .top) } }
            }
        }
        .sheet(item: $dialog) { target in
            if let folder = batch.collections.first(where: { $0.id == target.collectionID }) {
                switch target {
                case .notes: CollectionNotesSheet(folder: folder).environmentObject(batch)
                case .move: CollectionMoveSheet(folder: folder).environmentObject(batch)
                }
            }
        }
        .onChange(of: batch.collections.map(\.id)) { _, ids in
            if let location, !ids.contains(location) { open(nil) }
            if let dialog, !ids.contains(dialog.collectionID) { self.dialog = nil }
        }
        .onChange(of: batch.search) { _, _ in shown = 60 }
        .onChange(of: source) { _, _ in shown = 60 }
        .onAppear { store.reloadHistoryAfterFolderRecovery() }
        .onChange(of: batch.lastCollectionMove) { _, move in if let move { store.applyCollectionRelocation(move) } }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("学习文件夹").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { creating.toggle() } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue)).disabled(busy)
            }
            Text("按学习用途归类，把文案、标题和开头钩子的观察写在备注里。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            breadcrumbs
            WorkStatisticsControls(requests: statisticsRequests, skipped: statisticsItems.count - statisticsRequests.count, labels: statisticsLabels)
            if let issue = batch.error, !issue.isEmpty {
                Text(issue).font(.system(size: 12)).foregroundStyle(QQTheme.orange).textSelection(.enabled)
                    .padding(12).shiyingGlass(radius: 14)
            }
            if let notice = batch.notice, !notice.isEmpty {
                Text(notice).font(.system(size: 12)).foregroundStyle(QQTheme.teal).textSelection(.enabled)
            }
            if let current { folderHeading(current) }
            if creating { creationForm }
            let children = CollectionOrganization.children(of: location, in: batch.collections)
            if !children.isEmpty {
                LazyVGrid(columns: folders, alignment: .leading, spacing: 14) {
                    ForEach(children) { folder in folderTile(folder) }
                }
                Text("拖到另一个文件夹上可移入；「文件夹操作」可移动或调整同层顺序。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if current == nil {
                Text("创建一个学习文件夹，开始整理你的素材。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            if let current { folderContents(current) }
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { open(nil) } label: { Label("全部文件夹", systemImage: "folder") }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue))
                ForEach(CollectionOrganization.ancestors(of: location, in: batch.collections)) { folder in
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button(folder.name) { open(folder.id) }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue))
                }
            }
        }
    }

    private func open(_ id: UUID?) {
        if let id, !batch.collections.contains(where: { $0.id == id }) { return }
        location = id; shown = 60; batch.search = ""; creating = false; source = nil
        if let id { batch.selectCollection(id) }
    }
    private func goBack() { open(current?.parentID) }
    private func present(_ target: CollectionDialog) {
        guard !busy, batch.collections.contains(where: { $0.id == target.collectionID }) else { return }
        dialog = target
    }

    private var creationForm: some View {
        QQDepthSurface(radius: 18, padding: 16, accent: QQTheme.blue) {
            VStack(alignment: .leading, spacing: 10) {
                Text("创建在：" + (current?.name ?? "全部文件夹"))
                    .font(.system(size: 12, weight: .medium))
                TextField("文件夹名称，如：标题分析", text: $batch.newCollectionName)
                    .textFieldStyle(ShiyingGlassFieldStyle()).onSubmit { create() }
                Text("学习备注（可选）").font(.system(size: 12, weight: .medium))
                TextEditor(text: $creationNotes).font(.system(size: 13)).frame(height: 74)
                    .padding(8).shiyingGlass(radius: 12, inset: true).accessibilityLabel("新文件夹学习备注")
                Text("例如：整理标题的句式、对比开头如何吸引注意。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    if current == nil {
                        Button { batch.chooseParentFolder() } label: {
                            Label("保存到：" + URL(fileURLWithPath: batch.parentFolder).lastPathComponent, systemImage: "folder")
                        }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                    } else {
                        Text("子文件夹将创建在当前真实目录内。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消") { creating = false }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                    Button("创建") { create() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue))
                        .disabled(batch.newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.disabled(busy)
        }
    }

    private func create() {
        guard !busy else { return }
        if batch.createCollection(parentID: location, notes: creationNotes) {
            creationNotes = ""; open(batch.selectedCollectionID)
        }
    }

    private func folderTile(_ folder: StudyCollection) -> some View {
        let count = batch.items.filter { $0.collectionID == folder.id && $0.status == .completed }.count
        let childCount = CollectionOrganization.children(of: folder.id, in: batch.collections).count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Menu { folderActions(folder) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(busy)
                    .accessibilityLabel("文件夹操作：" + folder.name)
            }
            Button { open(folder.id) } label: {
                VStack(spacing: 8) {
                    Image(systemName: "folder.fill").symbolRenderingMode(.hierarchical)
                        .font(.system(size: 48)).foregroundStyle(QQTheme.blue)
                    Text(folder.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.center)
                    Text(folder.notes.isEmpty ? "尚未添加学习备注" : folder.notes)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(3).multilineTextAlignment(.center).help(folder.notes)
                    Text("\(count) 个作品" + (childCount > 0 ? " · \(childCount) 个子文件夹" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
            }
            .buttonStyle(QQGhostPressStyle(tint: QQTheme.blue, radius: 15))
            .accessibilityLabel(folder.name + "，\(count) 个作品，备注：" + (folder.notes.isEmpty ? "未添加" : folder.notes))
            .onDrag { NSItemProvider(object: ("shiying-folder:" + folder.id.uuidString) as NSString) }
        }
        .padding(12).shiyingGlass(radius: 18)
        .contextMenu { folderActions(folder).disabled(busy) }
        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
            guard !busy, let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let value = value as? String, value.hasPrefix("shiying-folder:"),
                      let id = UUID(uuidString: String(value.dropFirst("shiying-folder:".count))) else { return }
                DispatchQueue.main.async {
                    guard !store.busy else { return }
                    _ = batch.moveCollection(id, to: folder.id)
                }
            }
            return true
        }
    }

    @ViewBuilder private func folderActions(_ folder: StudyCollection) -> some View {
        Button("编辑学习备注…") { present(.notes(folder.id)) }
        Button("在此新建子文件夹") { open(folder.id); creating = true }
        Button("移动文件夹…") { present(.move(folder.id)) }
        Divider()
        Button("上移一位") { batch.reorderCollection(folder.id, by: -1) }
        Button("下移一位") { batch.reorderCollection(folder.id, by: 1) }
        Divider()
        Button("在访达中打开") { batch.selectCollection(folder.id); batch.openSelectedFolder() }
    }

    private func folderHeading(_ folder: StudyCollection) -> some View {
        QQDepthSurface(radius: 18, padding: 16, accent: QQTheme.blue) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Button(action: goBack) { Image(systemName: "arrow.turn.up.left") }
                        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                        .accessibilityLabel("返回上一级")
                    Label(folder.name, systemImage: "folder").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button { present(.notes(folder.id)) } label: { Label("编辑备注", systemImage: "square.and.pencil") }
                        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue)).disabled(busy)
                    Menu { folderActions(folder) } label: { Image(systemName: "ellipsis") }
                        .disabled(busy).accessibilityLabel("当前文件夹操作")
                }
                if folder.notes.isEmpty {
                    Text("写下这个文件夹的学习用途，备注会显示在文件夹名称下面。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text(folder.notes).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func folderContents(_ folder: StudyCollection) -> some View {
        let allItems = batch.items.filter { $0.collectionID == folder.id && $0.status == .completed &&
            (batch.search.isEmpty || ($0.title + " " + $0.author).localizedCaseInsensitiveContains(batch.search)) }
        let items = allItems.filter { source == nil || source == MediaSource.from(link: $0.link) }
        let visible = Array(items.prefix(shown))
        let counts = allItems.reduce(into: [MediaSource: Int]()) { $0[.from(link: $1.link), default: 0] += 1 }
        return VStack(alignment: .leading, spacing: 14) {
            Text("已保存的作品").font(.system(size: 14, weight: .semibold))
            TextField("搜索作品名称或博主", text: $batch.search).textFieldStyle(ShiyingGlassFieldStyle())
            ShiyingSourceFilter(selection: $source, counts: counts)
            if items.isEmpty {
                Text(batch.search.isEmpty ? "这个文件夹还没有已保存的作品。" : "没有匹配的作品。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 18)
            } else {
                ForEach(MediaSource.allCases) { group in
                    let grouped = visible.filter { MediaSource.from(link: $0.link) == group }
                    if !grouped.isEmpty {
                        ShiyingSourceHeading(source: group, count: grouped.count)
                        LazyVGrid(columns: videos, alignment: .leading, spacing: 14) {
                            ForEach(grouped) { item in
                                ShiyingVideoTile(title: item.title, author: item.author, description: item.description,
                                    path: item.path, imagePaths: item.imagePaths, coverPath: ShiyingCoverResolver.path(link: item.link, videoID: item.videoID, preferred: item.imagePaths?.first ?? item.path, candidates: coverCandidates), source: group, statistics: metrics.entry(link: item.link, videoID: item.videoID), historicalLikes: item.creatorDiggCount, historicalCollects: item.creatorCollectCount, statisticsChange: metrics.change(link: item.link, videoID: item.videoID), play: { batch.play(item) }, reveal: { batch.reveal(item) })
                            }
                        }
                    }
                }
                if shown < items.count {
                    Button("显示更多（\(shown)/\(items.count)）") { shown += 60 }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue))
                }
            }
        }
    }
}

private enum CollectionDialog: Identifiable {
    case notes(UUID), move(UUID)
    var collectionID: UUID { switch self { case .notes(let id), .move(let id): return id } }
    var id: String {
        switch self { case .notes: return "notes-" + collectionID.uuidString
        case .move: return "move-" + collectionID.uuidString }
    }
}

private struct CollectionNotesSheet: View {
    @EnvironmentObject var batch: BatchStore
    @Environment(\.dismiss) private var dismiss
    let folder: StudyCollection
    @State private var notes: String
    init(folder: StudyCollection) { self.folder = folder; _notes = State(initialValue: folder.notes) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(folder.name) · 学习备注").font(.system(size: 18, weight: .semibold))
            Text("写下学习用途、观察重点或复习时要看的内容。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $notes).font(.system(size: 14)).frame(height: 180)
                .padding(8).shiyingGlass(radius: 12, inset: true).accessibilityLabel("学习备注内容")
            if let issue = batch.error { Text(issue).font(.system(size: 12)).foregroundStyle(QQTheme.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                Button("保存备注") { if batch.updateCollectionNotes(folder.id, notes: notes) { dismiss() } }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue))
            }
        }.padding(24).frame(width: 490)
    }
}

private struct CollectionMoveSheet: View {
    @EnvironmentObject var batch: BatchStore
    @Environment(\.dismiss) private var dismiss
    let folder: StudyCollection
    @State private var parent: String
    init(folder: StudyCollection) { self.folder = folder; _parent = State(initialValue: folder.parentID?.uuidString ?? "root") }
    private var targetID: UUID? { UUID(uuidString: parent) }
    private var targets: [StudyCollection] {
        batch.collections.filter { (try? CollectionOrganization.validateParent($0.id, for: folder.id, in: batch.collections)) != nil }
    }
    private var targetPath: String {
        let directory = batch.collections.first { $0.id == targetID }?.path ?? batch.parentFolder
        return URL(fileURLWithPath: directory).appendingPathComponent(URL(fileURLWithPath: folder.path).lastPathComponent).path
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("移动「\(folder.name)」").font(.system(size: 18, weight: .semibold))
            Picker("目标文件夹", selection: $parent) {
                Text("全部文件夹（顶层）").tag("root")
                ForEach(targets) { target in Text(CollectionOrganization.title(of: target, in: batch.collections)).tag(target.id.uuidString) }
            }
            Text("文件夹及其中的视频、音轨会一起移动到：").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(targetPath).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let issue = batch.error { Text(issue).font(.system(size: 12)).foregroundStyle(QQTheme.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                Button("移动") { if batch.moveCollection(folder.id, to: targetID) { dismiss() } }
                    .buttonStyle(QQSoftButtonStyle(tint: QQTheme.blue))
            }
        }.padding(24).frame(width: 510)
    }
}
