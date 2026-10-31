import CoreGraphics
import Foundation
import ImageIO

/// ImageIO 嵌入预览提取 / Embedded preview extraction via ImageIO.
public enum RawPreview {
    /// 提取最大嵌入 JPEG（`FromImageIfAbsent=false`、`FromImageAlways=false`、不限尺寸，按方向旋正）；
    /// 文件里没有嵌入预览时返回 nil，不会退回解码主图。
    /// Extract the largest embedded JPEG (no max size, orientation applied); nil when the file has no embedded
    /// preview, never falling back to decoding the main image.
    ///
    /// # Examples
    /// ```
    /// let image = RawPreview.extract(url)
    /// print(image?.width ?? 0)
    /// ```
    public static func extract(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
