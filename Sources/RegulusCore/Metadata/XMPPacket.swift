import Foundation
import ImageIO

/// 要写进照片的元数据改动；nil 的字段不动 / Metadata changes to write into a photo; nil fields are left alone.
public struct MetadataEdit: Sendable, Equatable {
    /// `xmp:Rating`，0 表示清除（写成 0，不删标签），-1 表示排除 / `xmp:Rating`; 0 clears it (written as 0, the tag
    /// is kept), -1 means rejected.
    public var rating: Int?
    /// `xmp:Label`，空字符串表示清除（写成空值，不删标签）/ `xmp:Label`; an empty string clears it (written empty, the
    /// tag is kept).
    public var label: String?
    /// `dc:title`
    public var title: String?
    /// `dc:description`，照片原有 EXIF `ImageDescription` 时也一并替换（CR3/HEIC 原地放不下时删掉它）
    /// `dc:description`; also replaces the EXIF `ImageDescription` when the photo already has one (in CR3/HEIC it is
    /// removed when the new text does not fit in place).
    public var description: String?
    /// 追加到 `dc:subject` 的关键字（已有则不重复）/ Keyword added to `dc:subject` (once).
    public var keyword: String?

    public init(rating: Int? = nil, label: String? = nil, title: String? = nil, description: String? = nil,
                keyword: String? = nil) {
        self.rating = rating
        self.label = label
        self.title = title
        self.description = description
        self.keyword = keyword
    }
}

/// 用 ImageIO 解析、修改和序列化 XMP 包 / Parse, edit and serialise XMP packets with ImageIO.
enum XMPPacket {
    /// 给照片原有的 XMP 包（nil 或空时从空白开始）应用改动，返回新的 `x:xmpmeta`（不含 xpacket 外壳）；原有的其他属性都保留
    /// Apply the edit to the photo's existing XMP packet (starting blank when nil or empty) and return the new
    /// `x:xmpmeta` (no xpacket wrapper); every other existing property is kept.
    ///
    /// # Examples
    /// ```
    /// let xmp = try XMPPacket.updated(nil, MetadataEdit(rating: 4))
    /// ```
    ///
    /// - Throws: `RegulusError.metadata`：原有 XMP 解析不了或序列化失败 / when the existing XMP cannot be parsed or
    ///   serialisation fails.
    static func updated(_ packet: Data?, _ edit: MetadataEdit) throws -> Data {
        let metadata: CGMutableImageMetadata
        if let packet = packet.map(trimmed).map(normalized), !packet.isEmpty {
            guard let parsed = CGImageMetadataCreateFromXMPData(packet as CFData),
                  let copy = CGImageMetadataCreateMutableCopy(parsed) else {
                throw RegulusError.metadata("cannot parse the existing XMP")
            }
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        try apply(edit, to: metadata, keywords: keywords(metadata))
        guard let data = CGImageMetadataCreateXMPData(metadata, nil) else {
            throw RegulusError.metadata("cannot serialise XMP")
        }
        return data as Data
    }

    /// 把改动写到 metadata 上；keywords 是照片原有的关键字，新关键字追加在后面，整个 `dc:subject` 重写
    /// Apply the edit onto metadata; keywords are the photo's existing ones, the new keyword is appended and the whole
    /// `dc:subject` is rewritten.
    ///
    /// - Throws: `RegulusError.metadata`：某个属性设置失败 / when a property cannot be set.
    static func apply(_ edit: MetadataEdit, to metadata: CGMutableImageMetadata, keywords: [String]) throws {
        // 先删掉同名属性，有的照片会重复写 / remove existing copies first; some photos repeat a property
        let paths = [(edit.rating != nil, "xmp:Rating"), (edit.label != nil, "xmp:Label"), (edit.title != nil, "dc:title"),
                     (edit.description != nil, "dc:description"), (edit.keyword != nil, "dc:subject")]
        for (edited, path) in paths where edited {
            while CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) != nil,
                  CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString) {}
        }
        if let rating = edit.rating,
           !CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "\(rating)" as CFString) {
            throw RegulusError.metadata("cannot set xmp:Rating")
        }
        if let label = edit.label,
           !CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, label as CFString) {
            throw RegulusError.metadata("cannot set xmp:Label")
        }
        for (name, value) in [("title", edit.title), ("description", edit.description)] {
            guard let value else { continue }
            guard CGImageMetadataSetTagWithPath(metadata, nil, "dc:\(name)" as CFString, try langAlt(name, value)) else {
                throw RegulusError.metadata("cannot set dc:\(name)")
            }
        }
        if let keyword = edit.keyword {
            let all = keywords.contains(keyword) ? keywords : keywords + [keyword]
            guard let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                     "subject" as CFString, .arrayUnordered, all as CFArray),
                  CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, tag) else {
                throw RegulusError.metadata("cannot set dc:subject")
            }
        }
    }

    /// 加 xpacket 外壳并补空白到 size 字节（nil 时留 2KB 余量）；放不下返回 nil
    /// Wrap in xpacket and pad to size bytes (nil leaves 2 KB spare); nil when it does not fit.
    ///
    /// # Examples
    /// ```
    /// let packet = XMPPacket.wrapped(xmp, size: 4096)   // 正好 4096 字节 / exactly 4096 bytes
    /// ```
    static func wrapped(_ xmp: Data, size: Int?) -> Data? {
        let header = Data("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n".utf8)
        let trailer = Data("\n<?xpacket end=\"w\"?>".utf8)
        let fixed = header.count + xmp.count + trailer.count
        let target = size ?? fixed + 2048
        guard fixed <= target else { return nil }
        // 每 100 个空格换一行，和 Adobe 的写法一致 / a newline every 100 spaces, as Adobe writes it
        let padding = Data((0..<(target - fixed)).map { $0 % 100 == 99 ? 0x0A : 0x20 })
        return header + xmp + padding + trailer
    }

    /// 包成 size 字节，放不下时去掉标签间的空白再试 / Wrap to size bytes, retrying without whitespace between tags.
    static func fitted(_ xmp: Data, size: Int) -> Data? {
        if let packet = wrapped(xmp, size: size) { return packet }
        guard let text = String(data: xmp, encoding: .utf8) else { return nil }
        return wrapped(Data(text.replacingOccurrences(of: ">\\s+<", with: "><", options: .regularExpression).utf8), size: size)
    }

    /// dc:subject 里的关键字 / Keywords in dc:subject.
    static func keywords(_ metadata: CGImageMetadata) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString) else { return [] }
        let value = CGImageMetadataTagCopyValue(tag)
        if let items = value as? [CGImageMetadataTag] {
            return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
        }
        return (value as? String).map { [$0] } ?? []
    }

    /// lang-alt 属性（如 dc:title）第一项的文本（通常是 x-default）；不是数组时直接取值
    /// Text of the first item of a lang-alt property such as dc:title (usually x-default); a plain value is used as is.
    static func altText(_ metadata: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { return nil }
        let value = CGImageMetadataTagCopyValue(tag)
        if let items = value as? [CGImageMetadataTag] {
            return items.first.flatMap { CGImageMetadataTagCopyValue($0) as? String }
        }
        return value as? String
    }

    /// 构造只有 x-default 一项的 lang-alt 标签（ImageIO 不能直接创建，只能解析 XMP 得到），value 会做 XML 转义
    /// Build a lang-alt tag with a single x-default item (ImageIO can only get one by parsing XMP); value is XML-escaped.
    private static func langAlt(_ name: String, _ value: String) throws -> CGImageMetadataTag {
        let text = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let snippet = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\
            <dc:\(name)><rdf:Alt><rdf:li xml:lang="x-default">\(text)</rdf:li></rdf:Alt></dc:\(name)>\
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """
        guard let parsed = CGImageMetadataCreateFromXMPData(Data(snippet.utf8) as CFData),
              let tag = CGImageMetadataCopyTagWithPath(parsed, nil, "dc:\(name)" as CFString) else {
            throw RegulusError.metadata("cannot build dc:\(name)")
        }
        return tag
    }

    /// 去掉末尾的 NUL（有的相机按定长写 XMP）/ Drop trailing NULs (some cameras write fixed-length XMP).
    private static func trimmed(_ packet: Data) -> Data {
        var end = packet.endIndex
        while end > packet.startIndex, packet[end - 1] == 0 { end -= 1 }
        return packet[packet.startIndex..<end]
    }

    /// 命名空间声明改用双引号：ImageIO 解析不了 Sony 的单引号写法 / Double-quote namespace declarations: ImageIO
    /// cannot parse Sony's single-quoted ones.
    private static func normalized(_ packet: Data) -> Data {
        guard let text = String(data: packet, encoding: .utf8) else { return packet }
        return Data(text.replacingOccurrences(of: "xmlns:([A-Za-z0-9_.-]+)='([^'\"]*)'", with: "xmlns:$1=\"$2\"",
                                              options: .regularExpression).utf8)
    }
}
