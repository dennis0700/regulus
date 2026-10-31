import Foundation
import ImageIO

/// 照片文件里的星级、旗标和标题 / The stars, flag and title stored in a photo file.
public struct PhotoTags: Sendable, Equatable {
    /// 1–5 星，未评分为 nil / 1–5 stars; nil when unrated.
    public var rating: Int?
    public var flag: PhotoFlag?
    /// `dc:title`（App 写入的是中文鸟名）/ `dc:title` (the app writes the Chinese species name).
    public var title: String?

    public init(rating: Int? = nil, flag: PhotoFlag? = nil, title: String? = nil) {
        self.rating = rating
        self.flag = flag
        self.title = title
    }
}

/// 照片文件里的星级（`xmp:Rating`）和旗标（见 `PhotoFlag`），直接读写照片本身，不生成 .xmp 侧车
/// The star rating (`xmp:Rating`) and flag (see `PhotoFlag`) stored in the photo itself; no .xmp sidecar is created.
///
/// 相机机内评分、Lightroom 写进 JPEG/DNG 的评分都在这个标签里，所以它们也会被读出来。
/// 1–5 表示有评分；-1 是排除；0（相机默认就写 0）、其他值或没有这个标签都算未评分。
/// In-camera ratings and ratings Lightroom writes into JPEG/DNG use this tag too, so they are picked up.
/// 1–5 means rated; -1 is rejected; 0 (cameras write 0 by default), any other value or no tag is unrated.
public enum RatingFile {
    public static let range = 1...5

    /// 能否写入星级、旗标和鸟种：视频和富士 RAF（不是 TIFF 结构）不能，只能导入和查看
    /// Whether stars, flags and species can be written: not for videos or Fujifilm RAF (not a TIFF structure),
    /// which can only be imported and viewed.
    ///
    /// # Examples
    /// ```
    /// RatingFile.canWrite(URL(fileURLWithPath: "/Photos/DSCF0001.RAF"))   // false
    /// ```
    public static func canWrite(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext != "raf" && MediaKind(fileName: url.lastPathComponent) != .video
    }

    /// 读取一张照片的评分；未评分或文件打不开时返回 nil / Read a photo's rating; nil when unrated or unreadable.
    ///
    /// # Examples
    /// ```
    /// RatingFile.read(URL(fileURLWithPath: "/Photos/DSC00001.ARW"))   // 4
    /// ```
    public static func read(_ url: URL) -> Int? {
        tags(url).rating
    }

    /// 读取一张照片的星级、旗标和标题；文件打不开时全为 nil / Read a photo's stars, flag and title; all nil when
    /// the file cannot be opened.
    ///
    /// # Examples
    /// ```
    /// RatingFile.tags(URL(fileURLWithPath: "/Photos/DSC00001.ARW"))   // PhotoTags(rating: 4, flag: .picked, title: "池鹭")
    /// ```
    public static func tags(_ url: URL) -> PhotoTags {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        else { return PhotoTags() }
        let value = CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Rating" as CFString).flatMap(CGImageMetadataTagCopyValue)
        let stars = value.flatMap { Int(($0 as? String) ?? "\($0)") ?? ($0 as? NSNumber)?.intValue }
        let label = CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Label" as CFString)
            .flatMap(CGImageMetadataTagCopyValue) as? String
        let flag: PhotoFlag? = stars == -1 ? .rejected : label == PhotoFlag.pickedLabel ? .picked : nil
        return PhotoTags(rating: stars.flatMap { range.contains($0) ? $0 : nil }, flag: flag,
                         title: XMPPacket.altText(metadata, "dc:title"))
    }

    /// 并行读取多张照片（每张约 3ms，单线程读几千张会很慢）；结果只含有星级、旗标或标题的照片
    /// Read many photos in parallel (about 3 ms each, too slow for thousands on one thread); only photos with stars,
    /// a flag or a title are in the result.
    ///
    /// # Examples
    /// ```
    /// let tags = RatingFile.readAll([URL(fileURLWithPath: "/Photos/DSC00001.ARW")])   // [url: PhotoTags(rating: 4)]
    /// ```
    public static func readAll(_ urls: [URL]) -> [URL: PhotoTags] {
        let results = Results(count: urls.count)
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let tags = tags(urls[index])
            results.set(index, tags == PhotoTags() ? nil : tags)
        }
        return results.dictionary(keys: urls)
    }

    /// 写入评分（0 表示清除，即写入 `xmp:Rating` = 0）。先写到同目录的临时文件，校验通过后再原子替换原文件；
    /// 任何一步失败，原文件保持不变
    /// Write a rating (0 clears it by writing `xmp:Rating` = 0). A temp file in the same folder is written, verified
    /// and then atomically swapped in; if any step fails the original file is left untouched.
    ///
    /// 只改元数据，像素和预览不重新编码（写法见 `PhotoMetadataWriter`）/ Only metadata changes; pixels and previews
    /// are never re-encoded (see `PhotoMetadataWriter`).
    ///
    /// # Examples
    /// ```
    /// try RatingFile.write(4, to: URL(fileURLWithPath: "/Photos/DSC00001.ARW"))
    /// ```
    ///
    /// - Throws: `RegulusError.metadata`（星级不在 0–5、写入或校验失败）、`RegulusError.imageIO`（ImageIO 打不开）、
    ///   文件读写错误 / `RegulusError.metadata` for a rating outside 0–5 or a failed write or verification,
    ///   `RegulusError.imageIO` when ImageIO cannot open the file, or file I/O errors.
    public static func write(_ stars: Int, to url: URL) throws {
        guard stars == 0 || range.contains(stars) else { throw RegulusError.metadata("rating out of range: \(stars)") }
        try rewrite(url, edit: MetadataEdit(rating: stars)) { temp in
            let written = read(temp) ?? 0
            return written == stars ? nil : "rating \(written)"
        }
    }

    /// 把照片的旗标改成 flag：旗标写 `xmp:Label` = "Select"，排除写 `xmp:Rating` = -1（星级随之清除），
    /// 去掉旗标把对应的值清空；写完读回校验，失败时原文件不变
    /// Change the photo's flag to flag: picked writes `xmp:Label` = "Select", rejected
    /// writes `xmp:Rating` = -1 (clearing the stars), unflagging clears the matching value; read back to verify, and
    /// the original is untouched on failure.
    ///
    /// # Examples
    /// ```
    /// try RatingFile.write(.picked, to: URL(fileURLWithPath: "/Photos/DSC00001.ARW"))
    /// ```
    ///
    /// - Throws: 同 `rewrite` / as `rewrite`.
    public static func write(_ flag: PhotoFlag?, to url: URL) throws {
        let old = tags(url).flag
        guard flag != old else { return }
        var edit = MetadataEdit()
        if old == .rejected { edit.rating = 0 }
        if old == .picked { edit.label = "" }
        switch flag {
        case .picked: edit.label = PhotoFlag.pickedLabel
        case .rejected: edit.rating = -1
        case nil: break
        }
        try rewrite(url, edit: edit) { temp in
            let written = tags(temp).flag
            return written == flag ? nil : "flag \(written.map(\.rawValue) ?? "none")"
        }
    }

    /// 安全地改写照片的元数据：先写到同目录的临时文件，图像特征不变、check 通过（返回 nil）后
    /// 再原子替换原文件，保留创建和修改时间；任何一步失败，原文件保持不变
    /// Safely rewrite a photo's metadata: write a temp file in the same folder, and only when the image
    /// traits are unchanged and check passes (returns nil) atomically swap it in, keeping the creation and
    /// modification dates; if any step fails the original is left untouched.
    ///
    /// - Parameter check: 检查临时文件，失败时返回原因 / Inspects the temp file; returns a reason on failure.
    /// - Throws: `RegulusError.metadata`（写入或校验失败）、`RegulusError.imageIO`（ImageIO 打不开）、文件读写错误
    ///   `RegulusError.metadata` when writing or verification fails, `RegulusError.imageIO` when ImageIO cannot open
    ///   a file, or file I/O errors.
    static func rewrite(_ url: URL, edit: MetadataEdit, check: (URL) -> String?) throws {
        let before = try fingerprint(url)
        // 临时文件 `.名字.rating-tmp.扩展名`：以「.」开头，扫描和 FolderWatcher 都会忽略；保留原扩展名，因为 ImageIO
        // 靠扩展名识别部分 RAW（如 NEF），否则校验时打不开；上次残留的先删掉
        // Temp file `.name.rating-tmp.ext`: hidden, so scans and FolderWatcher ignore it; the extension is kept because
        // ImageIO relies on it to recognise some RAWs (e.g. NEF) and could not open it for verification otherwise;
        // a leftover from an earlier run is removed first
        let temp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.deletingPathExtension().lastPathComponent).rating-tmp.\(url.pathExtension)")
        try? FileManager.default.removeItem(at: temp)
        do {
            try PhotoMetadataWriter.write(edit, from: url, to: temp)
            let after = try fingerprint(temp)
            guard after == before else {
                throw RegulusError.metadata("verification failed for \(url.lastPathComponent): before \(before), after \(after)")
            }
            if let problem = check(temp) {
                throw RegulusError.metadata("verification failed for \(url.lastPathComponent): \(problem)")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let dates = attributes.filter { $0.key == .creationDate || $0.key == .modificationDate }
            try FileManager.default.setAttributes(dates, ofItemAtPath: temp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// 写入前后必须一致的图像特征：图像数量、主图尺寸、嵌入预览尺寸
    /// Image traits that must not change across a write: image count, primary size, embedded preview size.
    struct Fingerprint: Equatable {
        let count: Int
        let width: Int?
        let height: Int?
        let previewWidth: Int?
        let previewHeight: Int?
    }

    static func fingerprint(_ url: URL) throws -> Fingerprint {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw RegulusError.imageIO("cannot open \(url.lastPathComponent)") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false]
        let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        return Fingerprint(count: CGImageSourceGetCount(source),
                           width: properties[kCGImagePropertyPixelWidth] as? Int,
                           height: properties[kCGImagePropertyPixelHeight] as? Int,
                           previewWidth: preview?.width, previewHeight: preview?.height)
    }

    /// concurrentPerform 的结果收集（加锁）/ Lock-protected result collection for concurrentPerform.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PhotoTags?]

        init(count: Int) {
            values = Array(repeating: nil, count: count)
        }

        func set(_ index: Int, _ value: PhotoTags?) {
            lock.withLock { values[index] = value }
        }

        func dictionary(keys: [URL]) -> [URL: PhotoTags] {
            lock.withLock {
                var out: [URL: PhotoTags] = [:]
                for (key, value) in zip(keys, values) {
                    if let value { out[key] = value }
                }
                return out
            }
        }
    }
}
