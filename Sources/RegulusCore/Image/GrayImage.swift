import CoreGraphics

/// 8-bit 灰度图（行优先），由 RGB 按 Rec.601 转换，等价于 `cv2.cvtColor(RGB2GRAY)`。
/// 8-bit grayscale image (row-major), converted from RGB with Rec.601 like `cv2.COLOR_RGB2GRAY`.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    /// 直接用像素数组构造；长度不等于 width*height 时触发 precondition。
    /// Build from raw pixels; traps (precondition) unless count == width*height.
    ///
    /// # Examples
    /// ```
    /// let g = GrayImage(width: 2, height: 1, pixels: [0, 255])
    /// ```
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// 从 CGImage 生成灰度图：先经 `RGBA8Buffer(cgImage:)` 画进 sRGB 缓冲，再按 `init(rgba:)` 转灰度。
    /// Convert a CGImage: draw into an sRGB buffer via `RGBA8Buffer(cgImage:)`, then convert as `init(rgba:)`.
    ///
    /// # Examples
    /// ```
    /// let g = GrayImage(cgImage: cg)
    /// ```
    public init?(cgImage: CGImage) {
        guard let rgba = RGBA8Buffer(cgImage: cgImage) else { return nil }
        self.init(rgba: rgba)
    }

    /// 从 RGBA8 缓冲生成灰度图（cv2 定点：R*4899 + G*9617 + B*1868，+8192 后 >>14 即四舍五入；忽略第 4 字节）。
    /// From an RGBA8 buffer (cv2 fixed point: R*4899 + G*9617 + B*1868, +8192 then >> 14 = rounding; 4th byte ignored).
    ///
    /// # Examples
    /// ```
    /// let g = GrayImage(rgba: RGBA8Buffer(width: 1, height: 1, bytes: [255, 255, 255, 255]))
    /// assert(g.pixels == [255])
    /// ```
    public init(rgba: RGBA8Buffer) {
        var out = [UInt8](repeating: 0, count: rgba.width * rgba.height)
        rgba.bytes.withUnsafeBufferPointer { src in
            for i in 0..<out.count {
                let r = UInt32(src[i * 4]), g = UInt32(src[i * 4 + 1]), b = UInt32(src[i * 4 + 2])
                out[i] = UInt8((r * 4899 + g * 9617 + b * 1868 + 8192) >> 14)
            }
        }
        self.init(width: rgba.width, height: rgba.height, pixels: out)
    }
}
