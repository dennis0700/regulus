import Foundation

/// 要写到某个偏移处的字节 / Bytes to write at one offset.
struct BytePatch: Equatable {
    let offset: Int
    let bytes: Data
}

/// 按偏移读定长字节，读不满时抛错 / Read a fixed number of bytes at an offset; throws when short.
typealias ByteReader = (_ offset: Int, _ count: Int) throws -> Data

/// 改 TIFF 结构里 IFD0 的 XMP（700）和 ImageDescription（270）。新数据只追加到末尾，已有数据不移动
/// （新增 XMP 条目时在末尾另写一份 IFD0，旧的留在原处不再被引用）
/// Edit IFD0's XMP (700) and ImageDescription (270) in a TIFF structure. New data is only appended, existing data
/// never moves (adding an XMP entry writes a new IFD0 at the end; the old one stays, unreferenced).
enum TIFFMetadata {
    static let xmpTag = 700
    static let descriptionTag = 270

    /// 头里第 2–3 字节的 magic：TIFF 0x2A、ORF "RO"/"RS"、RW2 0x55 / Header magic: TIFF 0x2A, ORF "RO"/"RS", RW2 0x55.
    static let magics: Set<Int> = [0x2A, 0x4F52, 0x5352, 0x55]

    private struct Entry {
        let tag: Int
        let type: Int
        var count: Int
        /// 原样的 4 字节值或偏移 / The raw 4-byte value or offset.
        var value: Data
    }

    /// 算出改写需要的写入 / Work out the writes.
    ///
    /// # Examples
    /// ```
    /// let patches = try TIFFMetadata.plan(length: size, read: read, xmp: { try XMPPacket.updated($0, edit) },
    ///                                     description: nil, canAppend: true)
    /// ```
    ///
    /// - Parameters:
    ///   - length: TIFF 数据的长度，追加从这里开始 / Data length; appends start here.
    ///   - read: 按相对 TIFF 头的偏移读数据 / Reads data at offsets relative to the TIFF header.
    ///   - xmp: 旧 XMP 包 → 新 `x:xmpmeta`；nil 时不改 XMP / Old packet -> new `x:xmpmeta`; nil leaves XMP alone.
    ///   - addXMP: 没有 XMP 时是否新增 / Whether to add XMP when there is none.
    ///   - description: 只替换已有的 ImageDescription，没有时不新增 / Only replaces an existing ImageDescription;
    ///     none is added.
    ///   - canAppend: false 时只能原地改：XMP 放不下抛错，描述放不下删掉条目 / In place only: XMP that does not fit
    ///     throws, a description that does not fit has its entry removed.
    /// - Throws: `RegulusError.metadata`：不是 TIFF、结构损坏或放不下 / not TIFF, damaged, or does not fit.
    static func plan(length: Int, read: ByteReader, xmp: ((Data?) throws -> Data)?, addXMP: Bool = true,
                     description: String?, canAppend: Bool) throws -> [BytePatch] {
        let header = try read(0, 8)
        guard header.starts(with: [0x49, 0x49]) || header.starts(with: [0x4D, 0x4D]) else {
            throw RegulusError.metadata("not a TIFF structure")
        }
        let order = ByteOrder(little: header[header.startIndex] == 0x49)
        guard magics.contains(order.u16(header, 2)) else { throw RegulusError.metadata("unsupported TIFF variant") }
        let ifd = order.u32(header, 4)
        let count = order.u16(try read(ifd, 2), 0)
        let table = try read(ifd + 2, count * 12 + 4)
        var entries = (0..<count).map { i in
            Entry(tag: order.u16(table, i * 12), type: order.u16(table, i * 12 + 2), count: order.u32(table, i * 12 + 4),
                  value: table.subdata(in: (table.startIndex + i * 12 + 8)..<(table.startIndex + i * 12 + 12)))
        }
        var plan = Plan(length: length, order: order, canAppend: canAppend)
        if let xmp, addXMP || entries.contains(where: { $0.tag == xmpTag }) {
            try plan.xmp(&entries, read: read, update: xmp)
        }
        if let description, let index = entries.firstIndex(where: { $0.tag == descriptionTag }) {
            plan.description(&entries, at: index, description)
        }
        if let newIFD = plan.newIFD {
            // 新 IFD0 填进预留位置，头指向它 / the new IFD0 fills its reserved space; the header points to it
            let bytes = encode(entries, next: table.suffix(4), order)
            plan.tail.replaceSubrange((newIFD - length)..<(newIFD - length + bytes.count), with: bytes)
            plan.patches.append(BytePatch(offset: 4, bytes: order.bytes32(newIFD)))
        } else if plan.entriesChanged {
            plan.patches.append(BytePatch(offset: ifd, bytes: encode(entries, next: table.suffix(4), order)))
        }
        if !plan.tail.isEmpty { plan.patches.append(BytePatch(offset: length, bytes: plan.tail)) }
        return plan.patches
    }

    /// IFD：条目数、条目、下一个 IFD 的偏移 / An IFD: entry count, entries, offset of the next IFD.
    private static func encode(_ entries: [Entry], next: Data, _ order: ByteOrder) -> Data {
        entries.reduce(order.bytes16(entries.count)) {
            $0 + order.bytes16($1.tag) + order.bytes16($1.type) + order.bytes32($1.count) + $1.value
        } + next
    }

    /// 改写过程中累积的写入和追加 / Writes and appends gathered while planning.
    private struct Plan {
        let length: Int
        let order: ByteOrder
        let canAppend: Bool
        var patches: [BytePatch] = []
        var tail = Data()
        var entriesChanged = false
        /// 新 IFD0 在追加区里预留的偏移 / Offset reserved in the appended data for a new IFD0.
        var newIFD: Int?

        /// 追加到末尾（按 2 字节对齐），返回偏移 / Append at the end (2-byte aligned); returns the offset.
        mutating func append(_ bytes: Data) -> Int {
            if (length + tail.count) % 2 == 1 { tail.append(0) }
            let offset = length + tail.count
            tail += bytes
            return offset
        }

        /// 改写 XMP：原位置放得下（补空白到原长度）就原地写，否则追加到末尾并改条目。
        /// 要新增条目时在末尾写新的 IFD0，XMP 紧跟其后：IFD0 原地加不下条目，而且 ImageIO 会越过 IFD 多读几百字节（ORF 实测）
        /// Rewrite the XMP: in place when it fits (padded to the old length), otherwise appended with the entry updated.
        /// Adding an entry writes a new IFD0 at the end with the XMP right after it: the old IFD0 has no room for
        /// another entry, and ImageIO reads a few hundred bytes past an IFD (seen with ORF).
        mutating func xmp(_ entries: inout [Entry], read: ByteReader, update: (Data?) throws -> Data) throws {
            guard let index = entries.firstIndex(where: { $0.tag == TIFFMetadata.xmpTag }) else {
                guard canAppend else { throw RegulusError.metadata("no XMP to rewrite in place") }
                guard let packet = XMPPacket.wrapped(try update(nil), size: nil) else { return }
                newIFD = append(Data(count: 2 + (entries.count + 1) * 12 + 4))
                // XMP 条目类型为 BYTE(1)，条目按标签升序插入 / the XMP entry is of type BYTE(1); entries stay sorted by tag
                let entry = Entry(tag: TIFFMetadata.xmpTag, type: 1, count: packet.count, value: order.bytes32(append(packet)))
                entries.insert(entry, at: entries.firstIndex { $0.tag > TIFFMetadata.xmpTag } ?? entries.count)
                return
            }
            let entry = entries[index]
            let offset = order.u32(entry.value, 0)
            let old = entry.count > 4 ? try read(offset, entry.count) : entry.value.prefix(entry.count)
            let xmp = try update(old)
            if entry.count > 4, let packet = XMPPacket.wrapped(xmp, size: entry.count) {
                patches.append(BytePatch(offset: offset, bytes: packet))
            } else {
                guard canAppend, let packet = XMPPacket.wrapped(xmp, size: nil) else {
                    throw RegulusError.metadata("XMP does not fit in place")
                }
                clear(entry)
                entries[index].count = packet.count
                entries[index].value = order.bytes32(append(packet))
                entriesChanged = true
            }
        }

        /// 替换 ImageDescription：写 UTF-8 加结尾 NUL（条目类型不变）。原位置放得下就补 0 原地写；否则能追加就追加
        /// （不超过 4 字节时直接放进条目），不能追加就删掉条目
        /// Replace ImageDescription with UTF-8 plus a trailing NUL (entry type unchanged). Written in place, zero-padded,
        /// when it fits; otherwise appended (or stored inline when 4 bytes or less), or the entry is dropped when
        /// appending is not allowed.
        mutating func description(_ entries: inout [Entry], at index: Int, _ text: String) {
            let bytes = Data(text.utf8) + [0]
            let entry = entries[index]
            if let offset = stored(entry), bytes.count <= entry.count {
                patches.append(BytePatch(offset: offset, bytes: bytes + Data(count: entry.count - bytes.count)))
            } else if canAppend {
                clear(entry)
                entries[index].count = bytes.count
                entries[index].value = bytes.count <= 4 ? bytes + Data(count: 4 - bytes.count) : order.bytes32(append(bytes))
                entriesChanged = true
            } else {
                // 原地放不下：删掉条目 / does not fit in place: drop the entry
                clear(entry)
                entries.remove(at: index)
                entriesChanged = true
            }
        }

        /// 清零不再引用的旧值（有的软件会扫描整个文件找 XMP）/ Zero an old value no longer referenced (some software
        /// scans whole files for XMP).
        mutating func clear(_ entry: Entry) {
            guard let offset = stored(entry) else { return }
            patches.append(BytePatch(offset: offset, bytes: Data(count: entry.count)))
        }

        /// 值的偏移（超过 4 字节且在数据范围内时）/ Offset of an out-of-line value that lies inside the data.
        func stored(_ entry: Entry) -> Int? {
            let offset = order.u32(entry.value, 0)
            return entry.count > 4 && offset + entry.count <= length ? offset : nil
        }
    }
}

/// TIFF 字节序 / TIFF byte order.
struct ByteOrder {
    let little: Bool

    func u16(_ data: Data, _ at: Int) -> Int {
        let a = Int(data[data.startIndex + at]), b = Int(data[data.startIndex + at + 1])
        return little ? a | b << 8 : a << 8 | b
    }

    func u32(_ data: Data, _ at: Int) -> Int {
        let hi = u16(data, at), lo = u16(data, at + 2)
        return little ? lo << 16 | hi : hi << 16 | lo
    }

    func bytes16(_ value: Int) -> Data {
        let bytes = [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
        return Data(little ? bytes : bytes.reversed())
    }

    func bytes32(_ value: Int) -> Data {
        let bytes = (0..<4).map { UInt8(value >> ($0 * 8) & 0xFF) }
        return Data(little ? bytes : bytes.reversed())
    }
}
