import Foundation
import Testing
@testable import RegulusCore

// MARK: - 评分：与 SuperPicky 的 Python 实现逐条对照 / Rating: case-by-case parity with SuperPicky's Python engine

private struct RatingCase: Decodable {
    let birdFound: Bool
    let birdConfidence: Double
    let keypointVisibility: [Double]
    let headSharpness: Double
    let aesthetics: Double
    let flightProbability: Double
    let preset: String
    let expectedStars: Int
}

private struct RatingFixture: Decodable {
    let cases: [RatingCase]
}

@Test func ratingMatchesSuperPickyOnEveryFixtureCase() throws {
    let url = try #require(Bundle.module.url(forResource: "superpicky_rating_cases", withExtension: "json",
                                             subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(RatingFixture.self, from: Data(contentsOf: url))
    // SuperPicky 三档摄影水平预设 / SuperPicky's three skill presets
    let presets: [String: RatingThresholds] = ["beginner": RatingThresholds(sharpness: 300, aesthetics: 4.5),
                                               "intermediate": .intermediate,
                                               "master": RatingThresholds(sharpness: 520, aesthetics: 5.5)]
    #expect(fixture.cases.count > 1000)
    var mismatches: [String] = []
    for c in fixture.cases {
        let metrics = PhotoMetrics(birdFound: c.birdFound, birdConfidence: c.birdConfidence,
                                   keypointVisibility: c.keypointVisibility, headSharpness: c.headSharpness,
                                   aesthetics: c.aesthetics, flightProbability: c.flightProbability)
        let stars = RatingEngine.rate(metrics, thresholds: try #require(presets[c.preset])).stars
        if stars != c.expectedStars { mismatches.append("\(c) -> \(stars)") }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.first ?? "")")
}

@Test func roundingFollowsPythonHalfToEven() {
    // 3 星 × 可见度权重 0.5 = 1.5 → 2；1 星 × 0.5 = 0.5 → 0 / 3 stars × 0.5 = 1.5 → 2; 1 star × 0.5 = 0.5 → 0
    let lowEyes = [0.2, 0.1, 0.9]
    let three = PhotoMetrics(birdFound: true, birdConfidence: 0.9, keypointVisibility: lowEyes,
                             headSharpness: 600, aesthetics: 6)
    #expect(RatingEngine.rate(three, thresholds: .intermediate).stars == 2)
    let one = PhotoMetrics(birdFound: true, birdConfidence: 0.9, keypointVisibility: lowEyes,
                           headSharpness: 200, aesthetics: 4)
    #expect(RatingEngine.rate(one, thresholds: .intermediate).stars == 0)
}

@Test func flightBonusCanLiftAPhotoOverTheThreshold() {
    var m = PhotoMetrics(birdFound: true, birdConfidence: 0.9, keypointVisibility: [0.9, 0.9, 0.9],
                         headSharpness: 330, aesthetics: 4.5, flightProbability: 0.2)
    #expect(RatingEngine.rate(m, thresholds: .intermediate).stars == 1)
    m.flightProbability = 0.9   // 330×1.2=396 ≥ 380，4.5×1.1=4.95 ≥ 4.8
    let flying = RatingEngine.rate(m, thresholds: .intermediate)
    #expect(flying.stars == 3)
    #expect(flying.reason.contains("飞版加成"))
}

@Test func noBirdIsMinusOne() {
    #expect(RatingEngine.rate(PhotoMetrics(birdFound: false), thresholds: .intermediate).stars == -1)
}

@Test func speciesDisplayNamePrefersChinese() {
    let names = SpeciesNames(names: [.init(zh: "白鹭", en: "Little Egret", sci: "Egretta garzetta"),
                                     .init(zh: "", en: "Some Bird", sci: "Avis")])
    #expect(names.displayName(0) == "白鹭")
    #expect(names.displayName(1) == "Some Bird")
    #expect(names.displayName(99) == nil)
}

// MARK: - 端到端（本机有模型和样片时）/ End to end (when models and samples are present locally)

private let analyzerRepo = installedModelsRepo()

@Test(.enabled(if: PhotoAnalyzer(repo: analyzerRepo).missingFiles.isEmpty
          && FileManager.default.fileExists(atPath: "samples/jpeg/perched_cedar_waxwing.jpg")))
func analyzerRatesARealBirdAndNamesTheSpecies() async throws {
    let analyzer = PhotoAnalyzer(repo: analyzerRepo)
    let bird = try await analyzer.analyze(URL(fileURLWithPath: "samples/jpeg/perched_cedar_waxwing.jpg"),
                                          thresholds: .intermediate)
    #expect(bird.metrics.birdFound)
    #expect((bird.rating?.stars ?? -2) >= 0)
    let id = try #require(bird.metrics.speciesId)
    let names = try SpeciesNames(url: analyzerRepo.appendingPathComponent("models/birdtrace/species_names.json"))
    let name = try #require(names[id])
    #expect(name.en == "Cedar Waxwing", "got \(name.zh) / \(name.en)")

    let empty = try await analyzer.analyze(URL(fileURLWithPath: "samples/jpeg/negative_park_klodzko.jpg"),
                                           thresholds: .intermediate)
    #expect(empty.rating?.stars == -1)

    // RAW 走嵌入预览 / RAW goes through the embedded preview
    let raw = try await analyzer.analyze(URL(fileURLWithPath: "samples/raw/sony_a1_lossless.ARW"), thresholds: .intermediate)
    #expect((raw.rating?.stars ?? -2) >= -1)

    // 只评分不识别鸟种，只识别不评分 / rating only skips the species, identifying only skips the stars
    let url = URL(fileURLWithPath: "samples/jpeg/perched_cedar_waxwing.jpg")
    let rated = try await analyzer.analyze(url, thresholds: .intermediate, tasks: .rate)
    #expect(rated.metrics.speciesId == nil && rated.rating?.stars == bird.rating?.stars)
    let identified = try await analyzer.analyze(url, thresholds: .intermediate, tasks: .identify)
    #expect(identified.metrics.speciesId == bird.metrics.speciesId && identified.rating == nil)
}

@Test func starsOnlyWhenRating() {
    let rateMetrics = PhotoMetrics(birdFound: true, birdConfidence: 0.9, keypointVisibility: [0.9, 0.2, 0.8],
                                   headSharpness: 450, aesthetics: 5.2, flightProbability: 0.1)
    let rated = PhotoAnalyzer.record(rateMetrics, tasks: .rate, thresholds: .intermediate)
    #expect(rated.rating == RatingEngine.rate(rateMetrics, thresholds: .intermediate))

    // 只识别：有鸟种，评分留空 / identify only: species set, rating empty
    let idMetrics = PhotoMetrics(birdFound: true, birdConfidence: 0.9, speciesId: 42, speciesProbability: 0.8)
    let identified = PhotoAnalyzer.record(idMetrics, tasks: .identify, thresholds: .intermediate)
    #expect(identified.metrics.speciesId == 42 && identified.rating == nil)

    // 只识别时没找到鸟：直接记为无鸟 / identify only and no bird: recorded as no bird
    let none = PhotoAnalyzer.record(PhotoMetrics(birdFound: false), tasks: .identify, thresholds: .intermediate)
    #expect(none.rating?.stars == -1)
}

@Test func speciesInfoTiersAndIUCNTitles() throws {
    func info(iucn: String?, rarity: Double?) -> SpeciesInfo {
        SpeciesInfo(zh: "池鹭", en: "Chinese Pond Heron", sci: "Ardeola bacchus", inChina: true, order: "鹈鹕目",
                    family: "鹭科", genus: "池鹭属", iucn: iucn, rarity: rarity)
    }
    #expect(info(iucn: "LC", rarity: 0).rarityTier == "常见")
    #expect(info(iucn: "LC", rarity: 8).rarityTier == "能见")
    #expect(info(iucn: "LC", rarity: 49.9).rarityTier == "少见")
    #expect(info(iucn: "LC", rarity: 75).rarityTier == "传奇")
    #expect(info(iucn: "CR", rarity: nil).rarityTier == nil)
    #expect(info(iucn: "CR", rarity: nil).iucnTitle == "极危")
    #expect(info(iucn: nil, rarity: 1).iucnTitle == nil)

    // 与 build_species_info.py 生成的字段一致，缺省的 iucn/rarity 能读出 / matches the generated fields; missing keys decode
    let json = #"[{"zh":"雪松太平鸟","en":"Cedar Waxwing","sci":"Bombycilla cedrorum","inChina":false,"order":"雀形目","family":"太平鸟科","genus":""}]"#
    let entries = try JSONDecoder().decode([SpeciesInfo].self, from: Data(json.utf8))
    #expect(SpeciesInfoTable(entries: entries)[0]?.iucn == nil && SpeciesInfoTable(entries: entries)[1] == nil)
}
