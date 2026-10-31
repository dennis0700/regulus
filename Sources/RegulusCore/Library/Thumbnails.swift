import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// 解码出的图（网格缩略图或预览用的全尺寸图）和照片的原始尺寸
/// A decoded image (grid thumbnail or full-size preview) plus the photo's original pixel size.
public struct Thumbnail: @unchecked Sendable {
    // CGImage 不可变，跨线程只读是安全的 / CGImage is immutable and safe to read across threads
    public let image: CGImage
    /// 原图（不是 image）的像素尺寸，已按 EXIF 方向换算（竖拍为高 > 宽）
    /// The original's pixel size, not image's, already oriented (portrait shots are taller than wide).
    public let pixelWidth: Int
    public let pixelHeight: Int
}

/// 生成并缓存缩略图 / Makes and caches thumbnails.
///
/// RAW 用相机嵌入的预览，没有预览时才解码 RAW；JPEG/HEIF 总是从原图按目标尺寸降采样解码；视频取第一帧
/// RAWs use the camera's embedded preview, decoding the RAW only when there is none; JPEG/HEIF are always decoded
/// downsampled from the full image; videos use their first frame.
///
/// # Examples
/// ```
/// let cache = ThumbnailCache()
/// let thumb = await cache.thumbnail(for: url, maxPixelSize: 512)
/// ```
public final class ThumbnailCache: Sendable {
    private final class Entry {
        let thumbnail: Thumbnail
        init(_ thumbnail: Thumbnail) { self.thumbnail = thumbnail }
    }

    // NSCache 本身是线程安全的 / NSCache is thread-safe
    nonisolated(unsafe) private let cache = NSCache<NSString, Entry>()

    public init(countLimit: Int = 3000) {
        cache.countLimit = countLimit
    }

    /// 取缩略图：缓存按尺寸和文件修改时间区分，文件被改写后会重新生成；未命中时在后台（utility）生成
    /// Get a thumbnail, cached per size and modification time so a rewritten file is regenerated; misses are made
    /// in the background at utility priority.
    ///
    /// # Examples
    /// ```
    /// let thumb = await ThumbnailCache().thumbnail(for: URL(fileURLWithPath: "/Photos/DSC00001.ARW"), maxPixelSize: 512)
    /// ```
    public func thumbnail(for url: URL, maxPixelSize: Int) async -> Thumbnail? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(maxPixelSize)|\(modified?.timeIntervalSince1970 ?? 0)|\(url.path)" as NSString
        if let hit = cache.object(forKey: key) { return hit.thumbnail }
        let isVideo = MediaKind(fileName: url.lastPathComponent) == .video
        let made = await Task.detached(priority: .utility) {
            isVideo ? await Self.makeVideo(url, maxPixelSize: maxPixelSize) : Self.make(url, maxPixelSize: maxPixelSize)
        }.value
        if let made { cache.setObject(Entry(made), forKey: key) }
        return made
    }

    /// 清空缓存 / Empty the cache.
    ///
    /// # Examples
    /// ```
    /// cache.removeAll()
    /// ```
    public func removeAll() {
        cache.removeAllObjects()
    }

    /// 同步生成一张最长边不超过 maxPixelSize 的缩略图（已转正），不经过缓存；失败返回 nil
    /// Make one upright thumbnail, long side at most maxPixelSize, synchronously and uncached; nil on failure.
    ///
    /// # Examples
    /// ```
    /// let thumb = ThumbnailCache.make(URL(fileURLWithPath: "/Photos/DSC00001.JPG"), maxPixelSize: 512)
    /// ```
    public static func make(_ url: URL, maxPixelSize: Int) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let isRaw = PhotoLibrary.rawExtensions.contains(url.pathExtension.lowercased())
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // RAW：只用嵌入预览，没有才解码；JPEG：EXIF 里的小缩略图太糊，总是从原图降采样
            // RAW: embedded preview, decode only if absent; JPEG: the tiny EXIF thumbnail is too blurry, always downsample
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: !isRaw,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let (width, height) = orientedSize(source, fallback: image)
        return Thumbnail(image: image, pixelWidth: width, pixelHeight: height)
    }

    /// 视频第一帧的缩略图（已按视频的旋转转正），最长边不超过 maxPixelSize；读不了返回 nil
    /// A thumbnail of a video's first frame (turned upright by the video's rotation), long side at most maxPixelSize;
    /// nil when it cannot be read.
    ///
    /// # Examples
    /// ```
    /// let thumb = await ThumbnailCache.makeVideo(URL(fileURLWithPath: "/Photos/C0001.MP4"), maxPixelSize: 512)
    /// ```
    public static func makeVideo(_ url: URL, maxPixelSize: Int) async -> Thumbnail? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        // 原始尺寸按旋转换算 / the original size, after rotation
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return Thumbnail(image: image, pixelWidth: image.width, pixelHeight: image.height) }
        let turned = size.applying(transform)
        return Thumbnail(image: image, pixelWidth: Int(abs(turned.width).rounded()),
                         pixelHeight: Int(abs(turned.height).rounded()))
    }

    /// 预览用的全尺寸图（不进缓存）：TIFF 结构的 RAW 优先用内嵌的最大 JPEG（索尼 ARW 的 `JpgFromRaw` 是全尺寸的），
    /// 并按 RAW 记录的方向旋转；找不到时（如 CR3）用 ImageIO 给的嵌入预览；其他格式按原图尺寸解码。
    /// 这样得到的图最长边不到原图 90% 的 RAW（松下、奥林巴斯、只带小预览的 DNG）改用 CIRAWFilter 解码 RAW，
    /// 实测约 0.1 秒；解码失败时退回前面的结果
    /// Full-size image for the preview (not cached): TIFF-based RAWs use their largest embedded JPEG (a Sony ARW's
    /// `JpgFromRaw` is full size), rotated by the RAW's orientation; failing that (e.g. CR3) ImageIO's embedded
    /// preview; other formats decode at the original size. RAWs where this is under 90% of the original's long side
    /// (Panasonic, Olympus, DNGs with a small preview) decode the RAW with CIRAWFilter instead, about 0.1 s in
    /// measurements, falling back to the earlier result if that fails.
    ///
    /// 一张 5000 万像素的图约占 200MB 内存，用完就释放 / A 50 MP image takes about 200 MB; release it when done.
    ///
    /// # Examples
    /// ```
    /// let full = ThumbnailCache.makeFullSize(URL(fileURLWithPath: "/Photos/DSC00001.ARW"))   // 8640×5760
    /// ```
    public static func makeFullSize(_ url: URL) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let quick = quickFullSize(url, source: source)
        guard PhotoLibrary.rawExtensions.contains(url.pathExtension.lowercased()), isTooSmall(quick) else { return quick }
        return decodeRAW(url, source: source) ?? quick
    }

    /// 不解码 RAW 能拿到的最大图（没有任何预览的 RAW 例外，ImageIO 会解码）
    /// The largest image available without decoding the RAW (except a RAW with no preview at all, which ImageIO decodes).
    private static func quickFullSize(_ url: URL, source: CGImageSource) -> Thumbnail? {
        let isRaw = PhotoLibrary.rawExtensions.contains(url.pathExtension.lowercased())
        if isRaw, let jpeg = EmbeddedPreview.largest(in: url), let image = decode(jpeg, orientation: orientation(source)) {
            let (width, height) = orientedSize(source, fallback: image)
            return Thumbnail(image: image, pixelWidth: width, pixelHeight: height)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let longest = max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        return make(url, maxPixelSize: max(longest, 1024))
    }

    /// 没拿到图，或最长边不到原图的 90%（奥林巴斯内嵌 3200 宽，是原图的 62%，也要解码）
    /// Nothing at all, or the long side is under 90% of the original's (Olympus embeds 3200 wide, 62%, so it decodes too).
    static func isTooSmall(_ thumbnail: Thumbnail?) -> Bool {
        guard let thumbnail else { return true }
        return max(thumbnail.image.width, thumbnail.image.height) * 10 < max(thumbnail.pixelWidth, thumbnail.pixelHeight) * 9
    }

    /// 用 CIRAWFilter 解码 RAW（默认已按文件方向转正）/ Decode the RAW with CIRAWFilter (upright by default).
    private static func decodeRAW(_ url: URL, source: CGImageSource) -> Thumbnail? {
        guard let output = CIRAWFilter(imageURL: url)?.outputImage,
              let image = ciContext.createCGImage(output, from: output.extent, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        let (width, height) = orientedSize(source, fallback: image)
        return Thumbnail(image: image, pixelWidth: width, pixelHeight: height)
    }

    // CIContext 是线程安全的，创建开销大，共用一个 / CIContext is thread-safe and costly to create, so share one
    private static let ciContext = CIContext()

    /// 解码内嵌 JPEG 并转到显示方向（内嵌 JPEG 按传感器方向存，方向记在 RAW 里）
    /// Decode an embedded JPEG and turn it upright (it is stored in sensor orientation; the RAW holds the orientation).
    private static func decode(_ jpeg: Data, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        guard orientation != .up else { return image }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        return ciContext.createCGImage(oriented, from: oriented.extent, format: .RGBA8,
                                       colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
    }

    private static func orientation(_ source: CGImageSource) -> CGImagePropertyOrientation {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
    }

    /// 原图按方向换算后的尺寸（竖拍为高 > 宽）/ The original's size after orientation (portrait is taller than wide).
    private static func orientedSize(_ source: CGImageSource, fallback image: CGImage) -> (Int, Int) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? image.width
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? image.height
        // EXIF 方向 5–8 是旋转 90°，宽高要互换 / orientations 5–8 rotate by 90°, so swap
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        return (width, height)
    }
}
