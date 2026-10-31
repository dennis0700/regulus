import Foundation
import ImageIO

/// 把 `MetadataEdit` 写进照片本身，按文件内容选写法；像素和预览不重新编码
/// Write a `MetadataEdit` into the photo itself, chosen by file content; pixels and previews are never re-encoded.
enum PhotoMetadataWriter {
    /// 从 source 读、把改好的照片写到 destination（不存在的新文件）；source 不变。按文件头分派：
    /// FF D8 → JPEG；ftyp 品牌 `crx ` → CR3 原地改；其他 ftyp → HEIF（ImageIO）；其余按 TIFF 结构（多数 RAW）
    /// Read source and write the edited photo to destination (a new file); source is untouched. Dispatched on the
    /// header: FF D8 -> JPEG; ftyp brand `crx ` -> CR3 patched in place; other ftyp -> HEIF via ImageIO; anything
    /// else as a TIFF structure (most RAWs).
    ///
    /// # Examples
    /// ```
    /// try PhotoMetadataWriter.write(MetadataEdit(rating: 4), from: photo, to: temp)
    /// ```
    ///
    /// - Throws: `RegulusError.metadata`（不支持的格式或结构）、文件读写错误 / unsupported format or structure, or
    ///   file I/O errors.
    static func write(_ edit: MetadataEdit, from source: URL, to destination: URL) throws {
        let head = try FileHandle(forReadingFrom: source).readAndClose(upToCount: 12)
        if head.starts(with: [0xFF, 0xD8]) {
            try JPEGMetadata.write(edit, from: source, to: destination)
            return
        }
        if head.count == 12, head.subdata(in: 4..<8) == Data("ftyp".utf8) {
            let brand = String(decoding: head.subdata(in: 8..<12), as: UTF8.self)
            if brand == "crx " {
                try patchInPlace(source, destination) { try CR3Metadata.plan(edit, length: $0, read: $1) }
                return
            }
            try HEIFMetadata.write(edit, from: source, to: destination)
            return
        }
        try patchInPlace(source, destination) { length, read in
            try TIFFMetadata.plan(length: length, read: read, xmp: { try XMPPacket.updated($0, edit) },
                                  description: edit.description, canAppend: true)
        }
    }

    /// 复制一份（APFS 上是克隆，不占空间），再在副本上按 plan 的结果覆盖或在末尾追加字节
    /// Copy (a clone on APFS), then overwrite or append bytes in the copy as planned.
    static func patchInPlace(_ source: URL, _ destination: URL,
                             plan: (_ length: Int, _ read: ByteReader) throws -> [BytePatch]) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        let handle = try FileHandle(forUpdating: destination)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        let patches = try plan(length, handle.reader)
        for patch in patches {
            try handle.seek(toOffset: UInt64(patch.offset))
            try handle.write(contentsOf: patch.bytes)
        }
        try handle.synchronize()
    }
}

extension FileHandle {
    /// 按偏移读满 count 字节 / Read exactly count bytes at an offset.
    var reader: ByteReader {
        { offset, count in
            try self.seek(toOffset: UInt64(offset))
            let data = try self.read(upToCount: count) ?? Data()
            guard data.count == count else { throw RegulusError.metadata("unexpected end of file at \(offset)") }
            return data
        }
    }

    fileprivate func readAndClose(upToCount count: Int) throws -> Data {
        defer { try? close() }
        return try read(upToCount: count) ?? Data()
    }
}

/// ISO BMFF（CR3、HEIC）的 box / An ISO BMFF (CR3, HEIC) box.
struct BMFFBox {
    let type: String
    let start: Int
    let headerSize: Int
    let size: Int
    var payload: Int { start + headerSize }
    var payloadSize: Int { size - headerSize }

    /// 列出 range 内的同级 box / List the sibling boxes inside range.
    static func list(_ range: Range<Int>, read: ByteReader) throws -> [BMFFBox] {
        var boxes: [BMFFBox] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let header = try read(offset, 8)
            let order = ByteOrder(little: false)
            var size = order.u32(header, 0), headerSize = 8
            // size 1：后跟 64 位长度；size 0：延伸到 range 末尾 / size 1: a 64-bit size follows; size 0: runs to the end
            if size == 1 {
                let large = try read(offset + 8, 8)
                size = order.u32(large, 0) << 32 | order.u32(large, 4)
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= headerSize, offset + size <= range.upperBound else {
                throw RegulusError.metadata("damaged box at \(offset)")
            }
            boxes.append(BMFFBox(type: String(decoding: header.suffix(4), as: UTF8.self), start: offset,
                                 headerSize: headerSize, size: size))
            offset += size
        }
        return boxes
    }
}

/// CR3：原地改写顶层 XMP uuid box 里的 XMP 和 moov → Canon uuid → CMT1（IFD0）里已有的 ImageDescription，文件长度不变
/// CR3: the XMP in the top-level XMP uuid box and an existing ImageDescription in moov -> Canon uuid -> CMT1 (IFD0)
/// are rewritten in place; the length is unchanged.
enum CR3Metadata {
    /// 标准 XMP uuid box 的 UUID / UUID of the standard XMP uuid box.
    static let xmpUUID = Data([0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC])
    /// moov 里 Canon 元数据 uuid box（含 CMT1–CMT4）的 UUID / UUID of Canon's metadata uuid box in moov (holds CMT1–CMT4).
    static let canonUUID = Data([0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48])

    /// 算出 CR3 的写入：XMP 补空白到 box 原大小（放不下先去掉标签间空白）；ImageDescription 放不下时删掉条目
    /// Plan the CR3 writes: XMP padded to the box's size (whitespace between tags dropped if needed); an
    /// ImageDescription that does not fit has its entry removed.
    ///
    /// - Throws: `RegulusError.metadata`：没有 XMP box、放不下或结构损坏 / no XMP box, it does not fit, or damaged.
    static func plan(_ edit: MetadataEdit, length: Int, read: ByteReader) throws -> [BytePatch] {
        let top = try BMFFBox.list(0..<length, read: read)
        let uuids = try top.filter { $0.type == "uuid" && $0.payloadSize >= 16 }.map { ($0, try read($0.payload, 16)) }
        guard let box = uuids.first(where: { $0.1 == xmpUUID })?.0 else { throw RegulusError.metadata("CR3 without XMP box") }
        let size = box.payloadSize - 16
        guard let packet = XMPPacket.fitted(try XMPPacket.updated(try read(box.payload + 16, size), edit), size: size) else {
            throw RegulusError.metadata("XMP does not fit the CR3 XMP box")
        }
        var patches = [BytePatch(offset: box.payload + 16, bytes: packet)]
        if let description = edit.description, let cmt1 = try cmt1(top, read: read) {
            patches += try TIFFMetadata.plan(length: cmt1.payloadSize, read: { try read(cmt1.payload + $0, $1) }, xmp: nil,
                                             description: description, canAppend: false)
                .map { BytePatch(offset: cmt1.payload + $0.offset, bytes: $0.bytes) }
        }
        return patches
    }

    private static func cmt1(_ top: [BMFFBox], read: ByteReader) throws -> BMFFBox? {
        guard let moov = top.first(where: { $0.type == "moov" }) else { return nil }
        for box in try BMFFBox.list(moov.payload..<(moov.start + moov.size), read: read) where box.type == "uuid" {
            guard try read(box.payload, 16) == canonUUID else { continue }
            return try BMFFBox.list((box.payload + 16)..<(box.start + box.size), read: read).first { $0.type == "CMT1" }
        }
        return nil
    }
}

/// JPEG：整个读进内存，改写已有的 Exif APP1 段、替换或新增 XMP APP1 段，SOS 起的图像数据原样复制
/// JPEG: read whole, edit the existing Exif APP1 segment, replace or add the XMP APP1 segment; image data from SOS
/// on is copied as is.
enum JPEGMetadata {
    static let exifID = Data("Exif\0\0".utf8)
    static let xmpID = Data("http://ns.adobe.com/xap/1.0/\0".utf8)

    /// - Throws: `RegulusError.metadata`：JPEG 结构损坏或段超过 64KB / damaged JPEG or a segment over 64 KB.
    static func write(_ edit: MetadataEdit, from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        var segments: [(marker: UInt8, payload: Data)] = []
        var offset = 2
        while true {
            guard offset + 4 <= data.count, data[offset] == 0xFF else { throw RegulusError.metadata("damaged JPEG") }
            let marker = data[offset + 1]
            if marker == 0xDA { break }
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            guard length >= 2, offset + 2 + length <= data.count else { throw RegulusError.metadata("damaged JPEG") }
            segments.append((marker, data.subdata(in: (offset + 4)..<(offset + 2 + length))))
            offset += 2 + length
        }
        let isExif = { (s: (marker: UInt8, payload: Data)) in s.marker == 0xE1 && s.payload.starts(with: exifID) }
        let isXMP = { (s: (marker: UInt8, payload: Data)) in s.marker == 0xE1 && s.payload.starts(with: xmpID) }
        if let index = segments.firstIndex(where: isExif) {
            segments[index].payload = exifID + (try exif(segments[index].payload.dropFirst(exifID.count), edit))
        }
        let old = segments.first(where: isXMP).map { $0.payload.dropFirst(xmpID.count) }
        let body = try XMPPacket.updated(old.map { Data($0) }, edit)
        // 一个段最多 64KB，不支持 Extended XMP / one segment holds at most 64 KB; Extended XMP is not supported
        let limit = 0xFFFF - 2 - xmpID.count
        guard let packet = XMPPacket.wrapped(body, size: nil).flatMap({ $0.count <= limit ? $0 : nil })
                ?? XMPPacket.fitted(body, size: limit) else {
            throw RegulusError.metadata("XMP over 64 KB (Extended XMP is not supported)")
        }
        let xmp: (marker: UInt8, payload: Data) = (0xE1, xmpID + packet)
        if let index = segments.firstIndex(where: isXMP) {
            segments[index] = xmp
        } else {
            // 放在 JFIF / Exif 段之后 / after the JFIF / Exif segments
            let after = segments.firstIndex { !($0.marker == 0xE0 || isExif($0)) } ?? segments.count
            segments.insert(xmp, at: after)
        }
        var out = Data([0xFF, 0xD8])
        for segment in segments {
            guard segment.payload.count + 2 <= 0xFFFF else { throw RegulusError.metadata("JPEG segment over 64 KB") }
            out += Data([0xFF, segment.marker, UInt8((segment.payload.count + 2) >> 8), UInt8((segment.payload.count + 2) & 0xFF)])
            out += segment.payload
        }
        out += data.subdata(in: offset..<data.count)
        try out.write(to: destination, options: .withoutOverwriting)
    }

    /// 改 Exif 里的 ImageDescription，以及 IFD0 里已有的 XMP（ImageIO 会读它）/ Edit ImageDescription and any XMP
    /// already in IFD0 (ImageIO reads it).
    private static func exif(_ tiff: Data, _ edit: MetadataEdit) throws -> Data {
        var bytes = Data(tiff)
        let read: ByteReader = { offset, count in
            guard offset >= 0, offset + count <= bytes.count else { throw RegulusError.metadata("damaged Exif") }
            return bytes.subdata(in: offset..<(offset + count))
        }
        let patches = try TIFFMetadata.plan(length: bytes.count, read: read, xmp: { try XMPPacket.updated($0, edit) },
                                            addXMP: false, description: edit.description, canAppend: true)
        for patch in patches {
            if patch.offset + patch.bytes.count > bytes.count { bytes.count = patch.offset + patch.bytes.count }
            bytes.replaceSubrange(patch.offset..<(patch.offset + patch.bytes.count), with: patch.bytes)
        }
        return bytes
    }
}

/// HEIC：XMP 由 ImageIO 无损写入（不重新编码），再原地改 Exif 项里已有的 ImageDescription（ImageIO 读取时优先用它；
/// 放不下时删掉条目）
/// HEIC: XMP is written losslessly by ImageIO (no re-encode), then an existing ImageDescription in the Exif item is
/// edited in place (ImageIO prefers it when reading; the entry is dropped if the text does not fit).
enum HEIFMetadata {
    /// - Throws: `RegulusError.metadata`：ImageIO 写不了或 Exif 结构损坏；文件读写错误
    ///   `RegulusError.metadata` when ImageIO cannot write it or the Exif is damaged; file I/O errors.
    static func write(_ edit: MetadataEdit, from source: URL, to destination: URL) throws {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(image),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw RegulusError.metadata("ImageIO cannot write \(source.lastPathComponent)")
        }
        let existing = CGImageSourceCopyMetadataAtIndex(image, 0, nil)
        let metadata = CGImageMetadataCreateMutable()
        try XMPPacket.apply(edit, to: metadata, keywords: existing.map(XMPPacket.keywords) ?? [])
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(output, image, options as CFDictionary, nil) else {
            throw RegulusError.metadata("ImageIO cannot write \(source.lastPathComponent)")
        }
        guard let description = edit.description else { return }
        let handle = try FileHandle(forUpdating: destination)
        defer { try? handle.close() }
        let read = handle.reader
        guard let tiff = try exifTIFF(length: Int(try handle.seekToEnd()), read: read) else { return }
        let patches = try TIFFMetadata.plan(length: tiff.upperBound - tiff.lowerBound, read: { try read(tiff.lowerBound + $0, $1) },
                                            xmp: nil, description: description, canAppend: false)
        for patch in patches {
            try handle.seek(toOffset: UInt64(tiff.lowerBound + patch.offset))
            try handle.write(contentsOf: patch.bytes)
        }
        try handle.synchronize()
    }

    /// Exif 项里 TIFF 数据的位置（meta → iinf 找类型为 Exif 的项，iloc 找它的位置）
    /// Where the Exif item's TIFF data is (meta -> iinf for the item of type Exif, iloc for its location).
    static func exifTIFF(length: Int, read: ByteReader) throws -> Range<Int>? {
        guard let meta = try BMFFBox.list(0..<length, read: read).first(where: { $0.type == "meta" }) else { return nil }
        // meta 是 full box：先跳过 4 字节的 version/flags / meta is a full box: skip the 4-byte version/flags
        let children = try BMFFBox.list((meta.payload + 4)..<(meta.start + meta.size), read: read)
        guard let iinf = children.first(where: { $0.type == "iinf" }), let iloc = children.first(where: { $0.type == "iloc" }),
              let id = try exifItem(iinf, read: read), let extent = try location(of: id, iloc, read: read) else { return nil }
        let order = ByteOrder(little: false)
        // Exif 项开头 4 字节是到 TIFF 头的偏移 / the Exif item starts with a 4-byte offset to the TIFF header
        let start = extent.lowerBound + 4 + order.u32(try read(extent.lowerBound, 4), 0)
        return start < extent.upperBound ? start..<extent.upperBound : nil
    }

    private static func exifItem(_ iinf: BMFFBox, read: ByteReader) throws -> Int? {
        let order = ByteOrder(little: false)
        let version = Int(try read(iinf.payload, 1)[0])
        // version/flags 4 字节 + entry_count（v0 为 16 位，否则 32 位）/ 4-byte version/flags + entry_count (16-bit in v0)
        let skip = version == 0 ? 6 : 8
        for infe in try BMFFBox.list((iinf.payload + skip)..<(iinf.start + iinf.size), read: read) where infe.type == "infe" {
            let body = try read(infe.payload, min(infe.payloadSize, 16))
            guard let infeVersion = body.first.map(Int.init), infeVersion >= 2 else { continue }
            // infe v2 的 item_ID 是 16 位、v3 是 32 位，之后是 16 位 protection index 和 item_type
            // item_ID is 16-bit in infe v2 and 32-bit in v3, followed by a 16-bit protection index and item_type
            let typeAt = infeVersion == 2 ? 8 : 10
            guard body.count >= typeAt + 4 else { continue }
            if body.subdata(in: typeAt..<(typeAt + 4)) == Data("Exif".utf8) {
                return infeVersion == 2 ? order.u16(body, 4) : order.u32(body, 4)
            }
        }
        return nil
    }

    /// 只支持文件内单段存放（construction_method 0、一个 extent）/ Only single-extent items stored in the file.
    private static func location(of id: Int, _ iloc: BMFFBox, read: ByteReader) throws -> Range<Int>? {
        let order = ByteOrder(little: false)
        let body = try read(iloc.payload, iloc.payloadSize)
        guard body.count >= 6 else { throw RegulusError.metadata("damaged iloc") }
        var at = 6
        // 按字段宽度读整数，越界时抛错（损坏的文件）/ read an integer of the given width; throws past the end
        func int(_ size: Int) throws -> Int {
            guard at + size <= body.count else { throw RegulusError.metadata("damaged iloc") }
            defer { at += size }
            switch size {
            case 2: return order.u16(body, at)
            case 4: return order.u32(body, at)
            case 8: return order.u32(body, at) << 32 | order.u32(body, at + 4)
            default: return 0
            }
        }
        let version = Int(body[0]), sizes = Int(body[4]), more = Int(body[5])
        let offsetSize = sizes >> 4, lengthSize = sizes & 0xF, baseSize = more >> 4, indexSize = version >= 1 ? more & 0xF : 0
        let count = version < 2 ? try int(2) : try int(4)
        for _ in 0..<count {
            let item = version < 2 ? try int(2) : try int(4)
            let method = version >= 1 ? try int(2) & 0xF : 0
            _ = try int(2)   // data_reference_index
            let base = try int(baseSize)
            let extents = try int(2)
            var ranges: [Range<Int>] = []
            for _ in 0..<extents {
                _ = try int(indexSize)
                let offset = try int(offsetSize), length = try int(lengthSize)
                guard base >= 0, offset >= 0, length >= 0 else { throw RegulusError.metadata("damaged iloc") }
                ranges.append((base + offset)..<(base + offset + length))
            }
            if item == id { return method == 0 && ranges.count == 1 ? ranges[0] : nil }
        }
        return nil
    }
}
