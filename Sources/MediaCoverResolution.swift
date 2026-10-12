import Foundation

struct ShiyingCoverCandidate {
    let link: String
    var videoID: String? = nil
    var path: String? = nil
    var imagePaths: [String]? = nil
}

/// 借用路径只交给封面，播放和原始记录仍使用各自的文件。
enum ShiyingCoverResolver {
    static func path(link: String, videoID: String?, preferred: String?, candidates: [ShiyingCoverCandidate]) -> String? {
        if let own = localFile(preferred) { return own }
        guard let identity = WorkStatisticsRepository.request(link: link, videoID: videoID) else { return nil }
        let sameWork = candidates.filter { candidate in
            guard let other = WorkStatisticsRepository.request(link: candidate.link, videoID: candidate.videoID),
                  other.id == identity.id, other.platform == identity.platform else { return false }
            return true
        }
        for candidate in sameWork {
            if let media = localFile(candidate.path) { return media }
        }
        for candidate in sameWork {
            if let image = candidate.imagePaths?.compactMap({ localFile($0) }).first { return image }
        }
        return nil
    }

    static func localFile(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("://"),
              !path.contains("\0"), FileManager.default.isReadableFile(atPath: path),
              let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return path
    }
}
