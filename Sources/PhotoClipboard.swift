import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ShiyingPhotoClipboard {
    /// Eager PNG bytes keep the pasteboard usable after the temporary source is deleted.
    static func copy(path: String, pasteboard: NSPasteboard = .general) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw PhotoDraftError(message: "图片暂时无法读取，请重新解析后复制。")
        }
        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw PhotoDraftError(message: "图片复制失败。") }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw PhotoDraftError(message: "图片复制失败。") }
        let item = NSPasteboardItem()
        item.setData(bytes as Data, forType: .png)
        if let tiff = NSImage(cgImage: image, size: .zero).tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw PhotoDraftError(message: "剪贴板暂时不可写，请重试。") }
    }
}
