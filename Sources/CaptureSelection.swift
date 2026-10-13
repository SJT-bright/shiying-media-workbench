import Foundation

/// A missing option keeps the pre-option behavior: collect the video only.
struct CaptureSelection: Codable, Equatable {
    var video = true
    var cover = false
    var isValid: Bool { video || cover }

    init(video: Bool = true, cover: Bool = false) {
        self.video = video
        self.cover = cover
    }

    private enum CodingKeys: String, CodingKey { case video, cover }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        video = try values.decodeIfPresent(Bool.self, forKey: .video) ?? true
        cover = try values.decodeIfPresent(Bool.self, forKey: .cover) ?? false
    }
}
