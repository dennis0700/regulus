import Foundation
import ImageIO

/// 把鸟种信息写进照片文件本身（不生成 .xmp 侧车），Finder「显示简介」和其他软件都能看到：
/// 标题 `XMP-dc:Title` 为中文鸟名，描述 `XMP-dc:Description` 为名录信息（覆盖原有描述；照片已有 EXIF `ImageDescription`
/// 时也替换成同样文字，没有则不新增），关键字 `XMP-dc:Subject` 追加中文鸟名（已有则不重复）
/// Writes species info into the photo itself (no .xmp sidecar), visible in Finder's Get Info and other apps:
/// `XMP-dc:Title` is the Chinese name, `XMP-dc:Description` the checklist info (replacing any existing one; an existing
/// EXIF `ImageDescription` gets the same text, none is added), and the Chinese name is added to `XMP-dc:Subject` (once).
public enum SpeciesTagFile {
    /// 描述文字，每项一行：鸟名、分类（目 · 科 · 属，空的省略）、IUCN 等级、罕见度，不在中国名录时加一行说明；不含评分
    /// Description text, one item per line: names, taxonomy (order · family · genus, empty ones skipped), IUCN, rarity,
    /// and a note when not in the China checklist; no rating.
    ///
    /// # Examples
    /// ```
    /// SpeciesTagFile.description(info)
    /// // 领鸺鹠 Collared Owlet（Taenioptynx brodiei）
    /// // 鸮形目 · 鸱鸮科
    /// // IUCN 红色名录：LC 无危
    /// // 罕见度：能见（GBIF 15.1 / 100）
    /// ```
    public static func description(_ info: SpeciesInfo) -> String {
        var lines = [[info.zh, info.en].filter { !$0.isEmpty }.joined(separator: " ") + "（\(info.sci)）"]
        let taxonomy = [info.order, info.family, info.genus].filter { !$0.isEmpty }
        if !taxonomy.isEmpty { lines.append(taxonomy.joined(separator: " · ")) }
        if let code = info.iucn, let title = info.iucnTitle { lines.append("IUCN 红色名录：\(code) \(title)") }
        if let tier = info.rarityTier, let rarity = info.rarity {
            lines.append("罕见度：\(tier)（GBIF \(String(format: "%.1f", rarity)) / 100）")
        }
        if !info.inChina { lines.append("未收录于《中国鸟类名录》2026 版") }
        return lines.joined(separator: "\n")
    }

    /// 写入；写完读回校验，失败时原文件不变 / Write, then read back to verify; the original is untouched on failure.
    ///
    /// # Examples
    /// ```
    /// try SpeciesTagFile.write(info, to: URL(fileURLWithPath: "/Photos/DSC_7624.dng"))
    /// ```
    ///
    /// - Throws: 同 `RatingFile.rewrite`：主要是 `RegulusError.metadata`（写入或校验失败）
    ///   As `RatingFile.rewrite`: mainly `RegulusError.metadata` when writing or verification fails.
    public static func write(_ info: SpeciesInfo, to url: URL) throws {
        let text = description(info)
        // 已有的 EXIF 描述（如 SuperPicky 的评分说明）一并替换 / an existing EXIF description (e.g. SuperPicky's
        // rating caption) is replaced too
        let edit = MetadataEdit(title: info.zh, description: text, keyword: info.zh)
        try RatingFile.rewrite(url, edit: edit) { temp in
            guard let tags = read(temp) else { return "cannot read back" }
            if tags.title != info.zh { return "title \(tags.title ?? "nil")" }
            if tags.description != text { return "description differs" }
            return tags.keywords.contains(info.zh) ? nil : "keyword missing"
        }
    }

    /// 读出标题、描述和关键字（ImageIO 合并了 XMP 和 EXIF）；打不开时 nil
    /// Read the title, description and keywords (ImageIO merges XMP and EXIF); nil when the file cannot be opened.
    static func read(_ url: URL) -> (title: String?, description: String?, keywords: [String])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        return (XMPPacket.altText(metadata, "dc:title"), XMPPacket.altText(metadata, "dc:description"),
                XMPPacket.keywords(metadata))
    }
}
