import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// 模型输入的读图与预处理。读图优先直接拷贝解码后的 8-bit 字节（同 PIL/cv2，不做色彩管理），
/// 拷不了时才退回会做色彩匹配的 `RGBA8Buffer(cgImage:)`。
/// Loading and preprocessing for model inputs. Loading copies the decoded 8-bit bytes as-is when possible (like
/// PIL/cv2, no colour management) and only falls back to the colour-matching `RGBA8Buffer(cgImage:)` otherwise.
extension RGBA8Buffer {
    /// 读入用于分析的图像：扩展名属于 `PhotoLibrary.rawExtensions` 时取 `RawPreview.extract` 的嵌入预览
    /// （已按方向旋正，不解码 RAW，没有预览则抛错），其他格式同 `load(_:)`。
    /// Load the image used for analysis: for `PhotoLibrary.rawExtensions`, the embedded preview from
    /// `RawPreview.extract` (oriented, no RAW decode; throws if there is none); other formats as `load(_:)`.
    ///
    /// # Examples
    /// ```
    /// let img = try RGBA8Buffer.loadForAnalysis(URL(fileURLWithPath: "DSC00001.ARW"))
    /// ```
    public static func loadForAnalysis(_ url: URL) throws -> RGBA8Buffer {
        guard PhotoLibrary.rawExtensions.contains(url.pathExtension.lowercased()) else { return try load(url) }
        let preview = RawPreview.extract(url)
        guard let preview, let buf = RGBA8Buffer(rawPixelsOf: preview) ?? RGBA8Buffer(cgImage: preview) else {
            throw RegulusError.imageIO("no embedded preview in \(url.lastPathComponent)")
        }
        return buf
    }

    /// 解码第 0 帧并取 8-bit 像素；不应用 EXIF 方向。能直接拷字节时不做 ICC 转换。
    /// Decode frame 0 and take its 8-bit pixels; EXIF orientation is not applied. No ICC conversion when the bytes
    /// can be copied directly.
    ///
    /// # Examples
    /// ```
    /// let img = try RGBA8Buffer.load(URL(fileURLWithPath: "a.jpg"))
    /// ```
    public static func load(_ url: URL) throws -> RGBA8Buffer {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw RegulusError.imageIO("cannot decode \(url.lastPathComponent)")
        }
        guard let buf = RGBA8Buffer(rawPixelsOf: cg) ?? RGBA8Buffer(cgImage: cg) else {
            throw RegulusError.imageIO("cannot read pixels of \(url.lastPathComponent)")
        }
        return buf
    }

    /// 直接拷贝 CGImage 的 8-bit 字节（不经 CGContext，不做色彩匹配）。只接受 RGB 色彩空间、默认/大端字节序的
    /// RGB、RGBX/RGBA、XRGB/ARGB；alpha 丢弃（预乘值原样保留），其他格式返回 nil。
    /// Copy the CGImage's 8-bit bytes directly (no CGContext, no colour matching). Accepts only RGB colour spaces with
    /// default/big-endian order as RGB, RGBX/RGBA or XRGB/ARGB; alpha is dropped (premultiplied values kept as-is);
    /// nil otherwise.
    ///
    /// # Examples
    /// ```
    /// let buf = RGBA8Buffer(rawPixelsOf: cg) ?? RGBA8Buffer(cgImage: cg)
    /// ```
    public init?(rawPixelsOf cg: CGImage) {
        let alpha = cg.alphaInfo
        let order = cg.bitmapInfo.intersection(.byteOrderMask)
        guard cg.bitsPerComponent == 8, cg.colorSpace?.model == .rgb,
              order == [] || order == .byteOrderDefault || order == .byteOrder32Big,
              let data = cg.dataProvider?.data as Data? else { return nil }
        let bpp = cg.bitsPerPixel / 8
        let rgbOffset: Int
        switch (bpp, alpha) {
        case (3, .none): rgbOffset = 0
        case (4, .noneSkipLast), (4, .last), (4, .premultipliedLast): rgbOffset = 0
        case (4, .noneSkipFirst), (4, .first), (4, .premultipliedFirst): rgbOffset = 1
        default: return nil
        }
        let w = cg.width, h = cg.height, row = cg.bytesPerRow
        var out = [UInt8](repeating: 255, count: w * h * 4)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w {
                    let s = y * row + x * bpp + rgbOffset, d = (y * w + x) * 4
                    out[d] = src[s]
                    out[d + 1] = src[s + 1]
                    out[d + 2] = src[s + 2]
                }
            }
        }
        self.init(width: w, height: h, bytes: out)
    }

    /// 裁剪整数像素矩形；起点夹到图内，宽高夹到剩余范围且至少 1 像素。
    /// Crop to an integer pixel rect; the origin is clamped into the image and the size to what remains (min 1 px).
    ///
    /// # Examples
    /// ```
    /// let c = img.cropped(x: 0, y: 0, w: 10, h: 10)
    /// ```
    public func cropped(x: Int, y: Int, w: Int, h: Int) -> RGBA8Buffer {
        let x0 = max(0, min(width - 1, x)), y0 = max(0, min(height - 1, y))
        let cw = max(1, min(width - x0, w)), ch = max(1, min(height - y0, h))
        var out = [UInt8](repeating: 0, count: cw * ch * 4)
        bytes.withUnsafeBufferPointer { src in
            for row in 0..<ch {
                let s = ((y0 + row) * width + x0) * 4
                out.replaceSubrange(row * cw * 4..<(row + 1) * cw * 4, with: src[s..<s + cw * 4])
            }
        }
        return RGBA8Buffer(width: cw, height: ch, bytes: out)
    }

    /// 用 CoreGraphics 缩放（.medium≈双线性，.high≈Lanczos，用来近似 PIL/cv2 的对应插值）；
    /// 源与目标都标 sRGB，不做色彩转换；尺寸不变时原样返回。
    /// Resize with CoreGraphics (.medium ≈ bilinear, .high ≈ Lanczos, approximating the PIL/cv2 filters); both
    /// sides tagged sRGB so no conversion; returns self when the size is unchanged.
    ///
    /// # Examples
    /// ```
    /// let r = img.resized(width: 384, height: 384, quality: .high)
    /// ```
    public func resized(width w: Int, height h: Int, quality: CGInterpolationQuality) -> RGBA8Buffer? {
        if w == width && h == height { return self }
        guard let cg = cgImage(), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = quality
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? RGBA8Buffer(width: w, height: h, bytes: out) : nil
    }

    /// Ultralytics LetterBox(auto=false, center=true)：按比例缩放（.medium），居中贴到灰 114 的 size×size 画布。
    /// Ultralytics LetterBox(auto=false, center=true): aspect-preserving resize (.medium), centred on a gray-114
    /// size x size canvas.
    ///
    /// # Examples
    /// ```
    /// let lb = img.letterboxed(640)
    /// ```
    public func letterboxed(_ size: Int) -> Letterbox? {
        let r = min(Double(size) / Double(height), Double(size) / Double(width))
        let nw = Int((Double(width) * r).rounded()), nh = Int((Double(height) * r).rounded())
        let dw = Double(size - nw) / 2, dh = Double(size - nh) / 2
        // 同 Ultralytics 的 round(dw - 0.1)：奇数余量多出的 1 像素在右/下 / as Ultralytics: odd extra pixel goes right/bottom
        let left = Int((dw - 0.1).rounded()), top = Int((dh - 0.1).rounded())
        guard let scaled = resized(width: nw, height: nh, quality: .medium) else { return nil }
        var out = [UInt8](repeating: 114, count: size * size * 4)
        for y in 0..<nh {
            let d = ((y + top) * size + left) * 4
            out.replaceSubrange(d..<d + nw * 4, with: scaled.bytes[y * nw * 4..<(y + 1) * nw * 4])
        }
        return Letterbox(image: RGBA8Buffer(width: size, height: size, bytes: out), ratio: r, padX: left, padY: top)
    }

    /// 转 IOSurface 支持的 32BGRA CVPixelBuffer（Core ML 图像输入），alpha 填 255。
    /// Convert to an IOSurface-backed 32BGRA CVPixelBuffer (Core ML image input) with alpha set to 255.
    ///
    /// # Examples
    /// ```
    /// let pb = try img.pixelBuffer()
    /// ```
    public func pixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { throw RegulusError.model("CVPixelBufferCreate failed") }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw RegulusError.model("no base address") }
        let row = CVPixelBufferGetBytesPerRow(pb)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeBufferPointer { src in
            for y in 0..<height {
                for x in 0..<width {
                    let s = (y * width + x) * 4, d = y * row + x * 4
                    dst[d] = src[s + 2]
                    dst[d + 1] = src[s + 1]
                    dst[d + 2] = src[s]
                    dst[d + 3] = 255
                }
            }
        }
        return pb
    }
}

/// 信箱变换结果：信箱坐标 = 原图坐标 × ratio + (padX, padY)
/// Letterbox result: letterbox coords = original coords × ratio + (padX, padY).
public struct Letterbox: Sendable {
    public let image: RGBA8Buffer
    public let ratio: Double
    /// 左 / 上填充像素 / Left / top padding in pixels.
    public let padX: Int
    public let padY: Int

    /// 把信箱坐标系的 xyxy 框映射回原图像素，并夹到 [0, width] × [0, height]。
    /// Map an xyxy box from letterbox space back to original pixels, clamped to [0, width] × [0, height].
    ///
    /// # Examples
    /// ```
    /// let box = lb.unletterbox([10, 10, 100, 100], width: 1280, height: 720)
    /// ```
    public func unletterbox(_ b: [Double], width: Int, height: Int) -> [Double] {
        let px = Double(padX), py = Double(padY)
        return [min(Double(width), max(0, (b[0] - px) / ratio)), min(Double(height), max(0, (b[1] - py) / ratio)),
                min(Double(width), max(0, (b[2] - px) / ratio)), min(Double(height), max(0, (b[3] - py) / ratio))]
    }
}

/// SuperPicky 鸟裁剪：xyxy 框先截断成整数，四边各外扩长边的 15%（截断取整），夹到图内，返回 [x, y, w, h]。
/// SuperPicky bird crop: truncate the xyxy box to ints, pad each side by 15% of the long side (truncated), clamp
/// to the image; returns [x, y, w, h].
///
/// # Examples
/// ```
/// assert(paddedCropBox([20, 30, 120, 80], width: 1000, height: 1000) == [5, 15, 130, 80])
/// ```
public func paddedCropBox(_ box: [Double], width: Int, height: Int) -> [Int] {
    let x = Int(box[0]), y = Int(box[1]), w = Int(box[2]) - x, h = Int(box[3]) - y
    let pad = Int(Double(max(w, h)) * 0.15)
    let x0 = max(0, x - pad), y0 = max(0, y - pad)
    let x1 = min(width, x + w + pad), y1 = min(height, y + h + pad)
    return [x0, y0, x1 - x0, y1 - y0]
}
