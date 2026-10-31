import Foundation
import ImageIO

/// 已挂载的存储卡或普通文件夹里待导入的照片/视频文件 / A photo or video to import from a mounted card or folder.
public struct SourceFile: ImportItem, Equatable {
    public let url: URL
    public let size: Int64
    /// 拍摄日期（只含年月日，按相机本地时间，不做时区换算）/ Capture date (y/m/d only, camera-local, no timezone shift).
    public let captureDate: DateComponents

    public init(url: URL, size: Int64, captureDate: DateComponents) {
        self.url = url
        self.size = size
        self.captureDate = captureDate
    }

    public var name: String { url.lastPathComponent }

    public func contentHash() async throws -> String? {
        try PhotoImporter.sha256(of: url)
    }

    public func stage(to part: URL) async throws {
        try FileManager.default.copyItem(at: url, to: part)
    }

    public var importsConcurrently: Bool { true }

    public func preservedDates() -> [FileAttributeKey: Date] {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        var dates: [FileAttributeKey: Date] = [:]
        for key in [FileAttributeKey.creationDate, .modificationDate] {
            if let date = attributes[key] as? Date { dates[key] = date }
        }
        return dates
    }

    public func deleteSource() async throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// 导入时按内容类型分到的子文件夹 / The subfolder an imported file goes into, by content type.
public enum MediaKind: String, Sendable, CaseIterable {
    case raw = "Raw"
    case jpeg = "Jpeg"
    case heif = "HEIF"
    case video = "Video"

    /// 按扩展名判断类型（不区分大小写）；不认识的返回 nil / Kind from the file extension (case-insensitive); nil if unknown.
    ///
    /// # Examples
    /// ```
    /// MediaKind(fileName: "DSC00001.ARW")   // .raw
    /// MediaKind(fileName: "C0001.MP4")      // .video
    /// ```
    public init?(fileName: String) {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard let kind = Self.allCases.first(where: { $0.extensions.contains(ext) }) else { return nil }
        self = kind
    }

    public var extensions: Set<String> {
        switch self {
        case .raw: PhotoLibrary.rawExtensions
        case .jpeg: ["jpg", "jpeg"]
        case .heif: ["hif", "heif", "heic"]
        // crm：佳能 RAW 视频；nev：尼康 N-RAW 视频 / crm: Canon RAW movies; nev: Nikon N-RAW movies
        case .video: ["mov", "mp4", "mts", "mxf", "crm", "nev"]
        }
    }
}

/// 扫描导入源并读取拍摄日期 / Scans an import source and reads capture dates.
public enum MediaScanner {
    /// 照片库显示的照片类型：本项目支持的 RAW 加常见的 JPEG/HEIF / Photo types shown in the library: RAW plus JPEG/HEIF.
    public static let supportedExtensions: Set<String> = MediaKind.raw.extensions
        .union(MediaKind.jpeg.extensions).union(MediaKind.heif.extensions)

    /// 导入和照片库显示的文件类型：照片加视频 / Types imported and shown in the library: photos plus videos.
    public static let importExtensions: Set<String> = supportedExtensions.union(MediaKind.video.extensions)

    /// 存储卡根目录下相机建的文件夹：照片在 DCIM，索尼视频在 M4ROOT（CFexpress）或 PRIVATE/M4ROOT（SD），AVCHD 在
    /// PRIVATE/AVCHD，佳能 XF-HEVC S / XF-AVC S 视频在 XFVC、RAW 视频在 CRM；只录了视频的卡可能没有 DCIM
    /// Folders a camera creates at the card's root: photos in DCIM, Sony videos in M4ROOT (CFexpress) or
    /// PRIVATE/M4ROOT (SD), AVCHD in PRIVATE/AVCHD, Canon XF-HEVC S / XF-AVC S movies in XFVC and RAW movies in CRM;
    /// a card with only videos may have no DCIM.
    static let cardFolders = ["DCIM", "M4ROOT", "PRIVATE/M4ROOT", "PRIVATE/AVCHD", "XFVC", "CRM"]

    /// 不导入的索尼文件夹：THMBNL 是视频缩略图（JPG），SUB 是代理视频（原片能直接播放，代理多余）
    /// Sony folders that are not imported: THMBNL holds video thumbnails (JPG), SUB proxy videos (the originals play
    /// fine, so proxies are redundant).
    static let skippedFolders = ["M4ROOT/THMBNL", "M4ROOT/SUB"]

    /// 找出已挂载的相机存储卡（根目录下有 `cardFolders` 之一）/ Mounted camera cards (with one of `cardFolders` at
    /// the root).
    ///
    /// # Examples
    /// ```
    /// let cards = MediaScanner.cameraCards()
    /// ```
    public static func cameraCards() -> [URL] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.filter(isCameraCard)
    }

    static func isCameraCard(_ volume: URL) -> Bool {
        cardFolders.contains { folder in
            var isDirectory: ObjCBool = false
            let path = volume.appendingPathComponent(folder).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// 递归扫描目录，返回要导入的照片和视频，按路径排序 / Recursively scan a directory; photos and videos to import, sorted by path.
    ///
    /// 隐藏文件（包括存储卡上的 `._` 文件）和 `skippedFolders` 会被跳过 / Hidden files (including `._` files on cards)
    /// and `skippedFolders` are skipped.
    ///
    /// # Examples
    /// ```
    /// let files = try MediaScanner.scan(URL(fileURLWithPath: "/Volumes/EOS_DIGITAL/DCIM"))
    /// ```
    public static func scan(_ root: URL) throws -> [SourceFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var files: [SourceFile] = []
        for case let url as URL in walker {
            if skippedFolders.contains(where: { url.path.hasSuffix("/" + $0) }) {
                walker.skipDescendants()
                continue
            }
            guard importExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let date = exifDate(url) ?? fallbackDate(values.contentModificationDate)
            files.append(SourceFile(url: url, size: Int64(values.fileSize ?? 0), captureDate: date))
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    /// 读取 EXIF DateTimeOriginal 的年月日；没有 EXIF（如视频）或日期无效（如相机时钟未设置的 0000:00:00）时返回 nil，由调用方改用修改时间
    /// Y/M/D from EXIF DateTimeOriginal; nil when missing (e.g. videos) or invalid (e.g. 0000:00:00 from an unset
    /// clock), so the caller falls back to the modification time.
    static func exifDate(_ url: URL) -> DateComponents? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return parseExifDate(text)
    }

    /// 解析 "yyyy:MM:dd HH:mm:ss" 的日期部分；年份不在 1990–2100 或月日越界时返回 nil
    /// Parse the date part of "yyyy:MM:dd HH:mm:ss"; nil if the year is outside 1990–2100 or month/day is out of range.
    static func parseExifDate(_ text: String) -> DateComponents? {
        let parts = text.prefix(10).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3, (1990...2100).contains(parts[0]),
              (1...12).contains(parts[1]), (1...31).contains(parts[2])
        else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    /// EXIF 不可用时的日期：按本地时区取年月日，没有时间就用今天 / Fallback date: y/m/d in the local zone, today if nil.
    static func fallbackDate(_ modified: Date?) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: modified ?? Date())
    }
}
