import Foundation

/// 一个国家或省州及其 eBird 鸟种名录（鸟种库类别号）
/// A country or subnational region with its eBird species list (species-DB ids).
public struct Region: Codable, Sendable, Identifiable {
    /// eBird 地区代码，如 "CN"、"CN-35" / eBird region code, e.g. "CN", "CN-35".
    public let code: String
    public let en: String
    public let zh: String
    public let species: [Int]
    /// 国家下的省州；省州自身为 nil / Subnational regions of a country; nil for a subnational one.
    public let regions: [Region]?

    public var id: String { code }

    public init(code: String, en: String, zh: String, species: [Int], regions: [Region]? = nil) {
        self.code = code
        self.en = en
        self.zh = zh
        self.species = species
        self.regions = regions
    }
}

/// 各国家和省州的鸟种名录（superpicky-coreml 发布的 regions 数据包里的 regions.json）
/// Species lists per country and subnational region (regions.json in the regions data package released by
/// superpicky-coreml).
///
/// # Examples
/// ```
/// let checklist = try RegionChecklist(url: modelsDir.appendingPathComponent("regions.json"))
/// let tiers = checklist.tiers(country: "CN", province: "CN-35")   // [福建名录, 中国名录]
/// ```
public struct RegionChecklist: Sendable {
    public let countries: [Region]

    public init(url: URL) throws {
        countries = try JSONDecoder().decode([Region].self, from: Data(contentsOf: url))
    }

    public init(countries: [Region]) {
        self.countries = countries
    }

    /// 识别用的候选层：先省州、再国家（同 SuperPicky，不放宽到全世界）。省州不属于该国家时只用国家；
    /// 国家未知或为 nil 时返回空数组（不筛选）
    /// Candidate tiers for identification: the province, then the country (as SuperPicky, never widened to the
    /// world). A province outside the country is ignored; an unknown or nil country gives no tiers (no filtering).
    ///
    /// # Examples
    /// ```
    /// checklist.tiers(country: "CN", province: nil)   // [中国名录]
    /// ```
    public func tiers(country: String?, province: String?) -> [Set<Int>] {
        guard let country = countries.first(where: { $0.code == country }) else { return [] }
        let tiers = [country.regions?.first { $0.code == province }, country].compactMap { $0 }
        return tiers.map { Set($0.species) }
    }
}
