import Foundation
import Combine

/// One visible row owns one single-download transaction and its temporary files.
@MainActor final class SingleLinkItem: ObservableObject, Identifiable {
    let id = UUID()
    let link: String
    let position: Int
    let child: Store
    @Published var video: Video?
    @Published var photoDraft: Record?
    @Published var result: Record?
    @Published var error: String?
    @Published var detail = "等待解析"
    @Published var fraction: Double = 0
    @Published var busy = false
    @Published var status = "待解析"
    @Published private(set) var completedResults: [Record] = []
    var wasCancelled = false
    private let originalRecordIDs: Set<UUID>
    private var resolvedAlbum: Bool?
    var observation: AnyCancellable?
    var showRecord: ((Record, Int) -> Void)?

    init(link: String, position: Int, child: Store) {
        self.link = link; self.position = position; self.child = child
        originalRecordIDs = Set(child.records.map(\.id))
    }
    var photoPaths: [String] {
        if !child.photoPaths.isEmpty { return child.photoPaths }
        return completedResults.last(where: { $0.isAlbum })?.imagePaths ?? []
    }
    var photoMessage: String? { child.photoMessage }
    var overall: Double { child.overall }
    var confirmationTitle: String { child.confirmationTitle }
    var canConfirm: Bool { photoDraft != nil && !busy }
    var hasSavedResult: Bool { !completedResults.isEmpty }
    var isCompleted: Bool {
        guard hasSavedResult else { return false }
        if child.captureVideo && resolvedAlbum != true {
            let videoSaved = completedResults.contains { !$0.isAlbum }
            return videoSaved && (!child.captureCover || completedResults.contains(where: \.isCover))
        }
        return completedResults.contains { $0.isAlbum }
    }
    func copyPhoto(_ index: Int) {
        if !child.photoPaths.isEmpty { child.copyPhoto(index) }
        else if photoPaths.indices.contains(index) {
            do {
                try ShiyingPhotoClipboard.copy(path: photoPaths[index])
                child.photoMessage = "第 \(index + 1) 张图片已复制，可直接粘贴。"
            } catch { child.error = error.localizedDescription }
        }
        synchronize()
    }
    func play(_ record: Record, initialIndex: Int = 0) {
        if let showRecord { showRecord(record, initialIndex) }
        else { child.play(record, initialIndex: initialIndex) }
    }
    func reveal(_ record: Record) { child.reveal(record) }
    func applyCollectionRelocation(_ move: CollectionRelocation) {
        child.applyCollectionRelocation(move)
        completedResults = completedResults.map { original in
            var record = original
            if let path = record.path { record.path = CollectionOrganization.relocated(path, from: move.source, to: move.destination) }
            record.folder = CollectionOrganization.relocated(record.folder, from: move.source, to: move.destination)
            record.imagePaths = record.imagePaths?.map { CollectionOrganization.relocated($0, from: move.source, to: move.destination) }
            return record
        }
        synchronize()
    }
    func synchronize() {
        if let info = child.video { video = info; resolvedAlbum = info.isAlbum }
        photoDraft = child.photoDraft; result = child.result
        error = child.error; detail = child.detail; fraction = child.fraction; busy = child.busy
        if !busy, error == nil, child.photoDraft == nil, child.result == nil, child.video != nil {
            detail = "解析完成，准备下载"
        }
        if !busy, error == nil, wasCancelled, child.photoDraft == nil {
            detail = hasSavedResult ? "本条已取消，已保存文件保留" : "本条已取消，临时图片已清理"
        }
        for saved in child.records.reversed() where saved.status == "完成" && saved.link == link && !originalRecordIDs.contains(saved.id) {
            if !completedResults.contains(where: { $0.id == saved.id }) { completedResults.append(saved) }
        }
        if busy { status = child.downloading ? "下载中" : "解析中" }
        else if error != nil { status = "失败" }
        else if isCompleted { status = "已完成" }
        else if wasCancelled { status = "已取消" }
        else if photoDraft != nil { status = "待保存" }
        else if video != nil { status = "可下载" }
        else { status = "待解析" }
    }
}
