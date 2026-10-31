import Foundation

/// 鸟种名称表（下标即鸟种库类别号）/ Species name table (index = species-DB id).
public struct SpeciesNames: Sendable {
    public struct Name: Codable, Sendable, Equatable {
        public let zh: String
        public let en: String
        public let sci: String
    }

    let names: [Name]

    /// 读取 superpicky-coreml 导出的 species_names.json / Load species_names.json exported by superpicky-coreml.
    ///
    /// # Examples
    /// ```
    /// let names = try SpeciesNames(url: modelsDir.appendingPathComponent("birdtrace/species_names.json"))
    /// names[1]?.zh   // "灰颈鸵鸟"
    /// ```
    public init(url: URL) throws {
        names = try JSONDecoder().decode([Name].self, from: Data(contentsOf: url))
    }

    public init(names: [Name]) {
        self.names = names
    }

    /// 越界返回 nil / nil when out of range.
    public subscript(id: Int) -> Name? {
        names.indices.contains(id) ? names[id] : nil
    }

    /// 显示名：优先中文，其次英文；都为空或越界时为 nil
    /// Display name: Chinese, else English; nil if both are empty or the id is out of range.
    ///
    /// # Examples
    /// ```
    /// names.displayName(1)   // "灰颈鸵鸟"
    /// ```
    public func displayName(_ id: Int) -> String? {
        guard let name = self[id] else { return nil }
        return name.zh.isEmpty ? (name.en.isEmpty ? nil : name.en) : name.zh
    }
}
