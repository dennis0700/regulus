import CoreGraphics
import Foundation

/// sRGB 8-bit 像素缓冲，每像素 4 字节 R,G,B,X（行优先，无行填充）；第 4 字节不是有效 alpha，各处都忽略。
/// sRGB 8-bit pixel buffer, 4 bytes R,G,B,X per pixel (row-major, no row padding); the 4th byte is not a real
/// alpha and is ignored everywhere.
public struct RGBA8Buffer: Sendable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    /// 用 CGContext 把 CGImage 画进 sRGB RGBX 缓冲：非 sRGB 源会被色彩匹配，透明区域合成在黑底上。
    /// 需要原始字节时用 `init?(rawPixelsOf:)`；空图或建上下文失败返回 nil。
    /// Draw a CGImage into an sRGB RGBX buffer via CGContext: non-sRGB sources are colour-matched and transparent
    /// areas end up over black. Use `init?(rawPixelsOf:)` for untouched bytes; nil for empty images or context failure.
    ///
    /// # Examples
    /// ```
    /// let buf = RGBA8Buffer(cgImage: cg)
    /// ```
    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.width = w
        self.height = h
        self.bytes = data
    }

    /// 转成 CGImage（RGBX，sRGB）/ Convert to a CGImage (RGBX, sRGB).
    ///
    /// # Examples
    /// ```
    /// let img = RGBA8Buffer(width: 1, height: 1, bytes: [1, 2, 3, 255]).cgImage()
    /// ```
    public func cgImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 由已有字节构造；长度不等于 width*height*4 时触发 precondition。
    /// Build from existing bytes; traps (precondition) unless count == width*height*4.
    ///
    /// # Examples
    /// ```
    /// let buf = RGBA8Buffer(width: 1, height: 1, bytes: [1, 2, 3, 255])
    /// ```
    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "byte count mismatch")
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}
