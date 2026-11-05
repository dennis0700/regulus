import Foundation

/// 按中文名、拼音（全拼、首字母或混合，如 "xte"、"xiaotiane"、"xtian"）、英文名或学名查鸟种，给更正识别结果时输入用
/// Look up species by Chinese name, pinyin (full, initials or mixed, e.g. "xte", "xiaotiane", "xtian"), English or
/// scientific name; used to type a correction for an identification.
///
/// # Examples
/// ```
/// let search = SpeciesSearch(table: table)
/// search.ids(matching: "xte").first.flatMap { table[$0]?.zh }   // "小天鹅"
/// ```
public struct SpeciesSearch: Sendable {
    private struct Entry: Sendable {
        let id: Int
        let zh: String
        /// 每个汉字可能的读音（无声调），非汉字为空 / Possible readings (no tones) of each character; empty for non-Han.
        let syllables: [[String]]
        let latin: [String]
        let inChina: Bool
        let rarity: Double
    }

    private let entries: [Entry]

    /// 名录里常见的多音字：系统转换只给一个读音，鸟名里常用另一个（长尾、地鸫、藏雪鸡、秘鲁、鸿鹄）
    /// Polyphones common in the checklist: the system gives one reading, bird names often use another (长尾 chang,
    /// 地鸫 di, 藏雪鸡 zang, 秘鲁 bi, 鸿鹄 hu).
    static let extraReadings: [Character: [String]] = ["长": ["chang"], "地": ["di"], "藏": ["zang"], "秘": ["bi"],
                                                        "鹄": ["hu"], "角": ["jue"], "重": ["chong"], "朝": ["zhao"]]

    /// 拼音在这里算好（约 0.2 秒），宜在后台建 / Pinyin is computed here (about 0.2 s); build it in the background.
    public init(table: SpeciesInfoTable) {
        var readings: [Character: [String]] = [:]
        entries = table.entries.indices.map { id in
            let info = table.entries[id]
            let syllables = info.zh.map { character in
                if let cached = readings[character] { return cached }
                let found = Self.readings(of: character)
                readings[character] = found
                return found
            }
            return Entry(id: id, zh: info.zh, syllables: syllables,
                         latin: [info.en, info.sci].filter { !$0.isEmpty }.map { $0.lowercased() },
                         inChina: info.inChina, rarity: info.rarity ?? 100)
        }
    }

    /// 匹配的鸟种号，最相关的在前：先看匹配方式（中文名或拼音从开头匹配 > 英文名或学名从开头匹配 > 中文名或拼音从中间
    /// 匹配 > 英文名或学名从中间匹配），其次 preferred 里的（如拍摄地区名录）、中国名录里的，再按常见程度。空查询返回空
    /// Matching species ids, best first: by how they match (Chinese name or pinyin from the start > English or
    /// scientific name from the start > Chinese or pinyin mid-name > English or scientific mid-name), then those in
    /// preferred (e.g. the shooting region's list), then the China checklist, then the more common ones. An empty
    /// query gives nothing.
    public func ids(matching query: String, preferred: Set<Int> = [], limit: Int = 50) -> [Int] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return [] }
        let letters = Array(text.filter { !$0.isWhitespace })
        let isPinyin = letters.allSatisfy { $0.isASCII && $0.isLetter }
        let ranked = entries.compactMap { entry -> (Entry, Int)? in
            guard let kind = matchKind(of: text, letters: isPinyin ? letters : nil, in: entry) else { return nil }
            return (entry, kind)
        }
        return ranked.sorted { a, b in
            let keyA = (a.1, preferred.contains(a.0.id) ? 0 : 1, a.0.inChina ? 0 : 1)
            let keyB = (b.1, preferred.contains(b.0.id) ? 0 : 1, b.0.inChina ? 0 : 1)
            if keyA != keyB { return keyA < keyB }
            if a.0.rarity != b.0.rarity { return a.0.rarity < b.0.rarity }
            return a.0.zh.count < b.0.zh.count
        }
        .prefix(limit).map(\.0.id)
    }

    /// 匹配方式，越小越好：0 中文名或拼音从开头，1 英文名或学名从开头，2 中文名或拼音从中间，3 英文名或学名从中间；
    /// nil 为不匹配
    /// How it matches, lower is better: 0 Chinese or pinyin from the start, 1 English or scientific from the start,
    /// 2 Chinese or pinyin mid-name, 3 English or scientific mid-name; nil for no match.
    private func matchKind(of text: String, letters: [Character]?, in entry: Entry) -> Int? {
        if entry.zh.hasPrefix(text) { return 0 }
        if let letters, Self.matches(letters[...], entry.syllables[...]) { return 0 }
        if entry.latin.contains(where: { $0.hasPrefix(text) }) { return 1 }
        if entry.zh.contains(text) { return 2 }
        if let letters {
            for start in entry.syllables.indices.dropFirst() where Self.matches(letters[...], entry.syllables[start...]) {
                return 2
            }
        }
        return entry.latin.contains(where: { $0.contains(text) }) ? 3 : nil
    }

    /// 字母依次被各字读音的非空前缀用完（各字可只取首字母或多取几个）/ The letters are consumed in order by non-empty
    /// prefixes of each character's readings (an initial or more per character).
    static func matches(_ letters: ArraySlice<Character>, _ syllables: ArraySlice<[String]>) -> Bool {
        guard let first = letters.first else { return true }
        guard let readings = syllables.first else { return false }
        for reading in readings where reading.first == first {
            var length = 0
            for (a, b) in zip(reading, letters) {
                guard a == b else { break }
                length += 1
                if matches(letters.dropFirst(length), syllables.dropFirst()) { return true }
            }
        }
        return false
    }

    /// 一个汉字的读音（无声调）：系统的普通话转换加上 `extraReadings`；ü 同时给 v 和 u 两种写法
    /// A character's readings (no tones): the system Mandarin transform plus `extraReadings`; ü is given as both v
    /// and u.
    static func readings(of character: Character) -> [String] {
        guard character.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return [] }
        let latin = NSMutableString(string: String(character))
        guard CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false) else { return [] }
        // 按 Unicode 标量处理：ü 后跟声调时是一个字形簇，字符串替换匹配不到 / work on scalars: ü with a tone is a
        // single grapheme, which string replacement would not match
        var withV = ""
        var previous: Unicode.Scalar?
        for scalar in (latin as String).decomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar == "\u{308}", previous == "u" { withV.removeLast(); withV.append("v") }
            if scalar.isASCII { withV.unicodeScalars.append(scalar) }
            previous = scalar
        }
        var found: [String] = []
        for spelling in [withV, withV.replacingOccurrences(of: "v", with: "u")] + (extraReadings[character] ?? []) {
            let reading = spelling.lowercased()
            if !reading.isEmpty, reading.allSatisfy({ $0.isASCII && $0.isLetter }), !found.contains(reading) {
                found.append(reading)
            }
        }
        return found
    }
}
