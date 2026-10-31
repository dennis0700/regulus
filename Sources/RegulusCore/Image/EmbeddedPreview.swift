import Foundation

/// TIFF 结构的 RAW（ARW、NEF、DNG 等）里内嵌的 JPEG 预览
/// JPEG previews embedded in TIFF-based RAWs (ARW, NEF, DNG, ...).
///
/// ImageIO 的缩略图接口对索尼 ARW 只给 IFD0 里 1616 宽的小预览，不理会 IFD2 里的全尺寸 `JpgFromRaw`，
/// 所以这里自己沿着 IFD 链和 SubIFD 找出全部内嵌 JPEG（标签 0x0201 偏移 / 0x0202 长度），取字节数最大的一张。
/// CR3 不是 TIFF 结构，会返回 nil。
/// ImageIO's thumbnail API only hands out the 1616-wide preview in IFD0 of a Sony ARW and ignores the full-size
/// `JpgFromRaw` in IFD2, so this walks the IFD chain and SubIFDs for every embedded JPEG (tag 0x0201 offset /
/// 0x0202 length) and takes the largest by byte count. CR3 is not TIFF-based and yields nil.
public enum EmbeddedPreview {
    /// 最多看多少个 IFD，防止损坏文件里的环 / Cap on IFDs visited, guarding against loops in broken files.
    static let maxDirectories = 64

    /// 文件里最大（按字节数）的内嵌 JPEG 数据；不是 TIFF 结构、读不了或没有时返回 nil
    /// The largest (by byte count) embedded JPEG data in the file; nil if it is not TIFF-based, unreadable, or has none.
    ///
    /// # Examples
    /// ```
    /// let jpeg = EmbeddedPreview.largest(in: URL(fileURLWithPath: "/Photos/DSC00001.ARW"))   // 8640×5760 的 JpgFromRaw
    /// ```
    public static func largest(in url: URL) -> Data? {
        // 内存映射：只会读到用到的几页（目录和那张 JPEG），不会把整个 RAW 读进内存
        // Memory-mapped: only the pages touched (directories and that JPEG) are read, not the whole RAW
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return largest(inTIFF: data)
    }

    /// 遍历 IFD0 起的 next 链和所有 SubIFD（偏移 0 表示没有、访问过的跳过），取以 FF D8 开头的最长 JPEG
    /// Walk the next chain from IFD0 and every SubIFD (offset 0 means none; visited ones are skipped) and take the
    /// longest JPEG that starts with FF D8.
    static func largest(inTIFF data: Data) -> Data? {
        guard let reader = TIFFReader(data) else { return nil }
        var best: Range<Int>?
        var pending = [reader.firstDirectory]
        var visited = Set<Int>()
        while let offset = pending.popLast() {
            guard offset > 0, visited.count < maxDirectories, visited.insert(offset).inserted,
                  let directory = reader.directory(at: offset) else { continue }
            pending.append(directory.next)
            pending.append(contentsOf: directory.subDirectories)
            if let jpeg = directory.jpeg, jpeg.count > (best?.count ?? 0), reader.isJPEG(jpeg) {
                best = jpeg
            }
        }
        return best.map { reader.bytes($0) }
    }
}

/// 只读 TIFF 目录里用得到的几个标签 / Reads only the few TIFF directory tags needed here.
private struct TIFFReader {
    struct Directory {
        var next = 0
        var subDirectories: [Int] = []
        var jpeg: Range<Int>?
    }

    let data: Data
    let littleEndian: Bool

    init?(_ data: Data) {
        self.data = data
        switch (Self.byte(data, 0), Self.byte(data, 1)) {
        case (0x49, 0x49): littleEndian = true    // "II"
        case (0x4D, 0x4D): littleEndian = false   // "MM"
        default: return nil
        }
        guard u16(2) == 42 else { return nil }
    }

    var firstDirectory: Int { u32(4).map(Int.init) ?? 0 }

    func directory(at offset: Int) -> Directory? {
        guard let count = u16(offset).map(Int.init) else { return nil }
        var directory = Directory()
        var start: Int?
        var length: Int?
        for index in 0..<count {
            let entry = offset + 2 + index * 12
            guard let tag = u16(entry), let type = u16(entry + 2), let n = u32(entry + 4).map(Int.init) else { return nil }
            let value = entry + 8
            switch tag {
            case 0x0201: start = u32(value).map(Int.init)
            case 0x0202: length = u32(value).map(Int.init)
            // SubIFDs：LONG(4) 或 IFD(13)；超过一个时 value 是数组的偏移；最多取 16 个
            // SubIFDs: LONG(4) or IFD(13); with more than one, value is the offset of the array; at most 16 are taken
            case 0x014A where type == 4 || type == 13:
                let base = n == 1 ? value : (u32(value).map(Int.init) ?? -1)
                directory.subDirectories += (0..<min(n, 16)).compactMap { u32(base + $0 * 4).map(Int.init) }
            default: break
            }
        }
        if let start, let length, length > 2 { directory.jpeg = start..<(start + length) }
        directory.next = u32(offset + 2 + count * 12).map(Int.init) ?? 0
        return directory
    }

    /// 范围在文件内，并以 JPEG 的 SOI（FF D8）开头 / In bounds and starting with a JPEG SOI (FF D8).
    func isJPEG(_ range: Range<Int>) -> Bool {
        range.lowerBound >= 0 && range.upperBound <= data.count
            && Self.byte(data, range.lowerBound) == 0xFF && Self.byte(data, range.lowerBound + 1) == 0xD8
    }

    func bytes(_ range: Range<Int>) -> Data {
        data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
    }

    private func u16(_ offset: Int) -> UInt16? {
        guard let a = Self.byte(data, offset), let b = Self.byte(data, offset + 1) else { return nil }
        return littleEndian ? UInt16(a) | UInt16(b) << 8 : UInt16(a) << 8 | UInt16(b)
    }

    private func u32(_ offset: Int) -> UInt32? {
        guard let low = u16(littleEndian ? offset : offset + 2), let high = u16(littleEndian ? offset + 2 : offset)
        else { return nil }
        return UInt32(high) << 16 | UInt32(low)
    }

    private static func byte(_ data: Data, _ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }
}
