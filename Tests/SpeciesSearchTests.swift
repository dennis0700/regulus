import Foundation
import Testing
@testable import RegulusCore

private func species(_ zh: String, _ en: String, _ sci: String, inChina: Bool = true, rarity: Double? = nil) -> SpeciesInfo {
    SpeciesInfo(zh: zh, en: en, sci: sci, inChina: inChina, order: "", family: "", genus: "", iucn: nil, rarity: rarity)
}

private let table = SpeciesInfoTable(entries: [
    species("大天鹅", "Whooper Swan", "Cygnus cygnus", rarity: 10),
    species("小天鹅", "Tundra Swan", "Cygnus columbianus", rarity: 12),
    species("长尾山雀", "Long-tailed Tit", "Aegithalos caudatus", rarity: 5),
    species("白头鹎", "Light-vented Bulbul", "Pycnonotus sinensis", rarity: 3),
    species("绿头鸭", "Mallard", "Anas platyrhynchos", rarity: 1),
    species("小天堂鸟", "Lesser Bird-of-paradise", "Paradisaea minor", inChina: false, rarity: 40),
])
private let search = SpeciesSearch(table: table)

private func names(_ query: String, preferred: Set<Int> = []) -> [String] {
    search.ids(matching: query, preferred: preferred).compactMap { table[$0]?.zh }
}

@Test func pinyinInitialsFullAndMixedFindTheSpecies() {
    #expect(names("xte") == ["小天鹅"])
    #expect(names("xiaotiane") == ["小天鹅"])
    #expect(names("xtian").first == "小天鹅")
    #expect(names("XTE") == ["小天鹅"])
}

@Test func polyphonesInBirdNamesMatchBothReadings() {
    #expect(names("cwsq") == ["长尾山雀"])
    #expect(names("zwsq") == ["长尾山雀"])
    // ü 可写作 v 或 u / ü can be typed as v or u
    #expect(names("lvty") == ["绿头鸭"])
    #expect(names("luty") == ["绿头鸭"])
}

@Test func chineseEnglishAndScientificNamesMatch() {
    #expect(names("天鹅") == ["大天鹅", "小天鹅"])
    #expect(names("mallard") == ["绿头鸭"])
    #expect(names("cygnus") == ["大天鹅", "小天鹅"])
    #expect(names("") == [])
    #expect(names("qqqq") == [])
}

@Test func rankingPrefersStartMatchesThenRegionThenChinaThenCommon() {
    // 「xt」：小天鹅（中国，常见些）在小天堂鸟（国外）之前；从中间匹配的大天鹅最后
    // "xt": 小天鹅 (China) before 小天堂鸟 (abroad); 大天鹅, matched mid-name, comes last
    #expect(names("xt") == ["小天鹅", "小天堂鸟"])
    #expect(names("tiane") == ["大天鹅", "小天鹅"])
    #expect(names("tiane", preferred: [1]) == ["小天鹅", "大天鹅"])
}

/// 真实名录里的例子（装了模型时才跑）/ Examples on the real checklist (only with the models installed).
@Test(.enabled(if: FileManager.default.fileExists(atPath: realChecklist.path)))
func realChecklistFindsCommonBirdsByInitials() throws {
    let table = try SpeciesInfoTable(url: realChecklist)
    let search = SpeciesSearch(table: table)
    let first = { (query: String) in search.ids(matching: query).first.flatMap { table[$0]?.zh } }
    #expect(first("xte") == "小天鹅")
    #expect(first("btb") == "白头鹎")
    #expect(first("bcwsq") == "北长尾山雀")
    #expect(first("bl") == "白鹭")
}

private let realChecklist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Regulus/models/birdtrace/species_info.json")
