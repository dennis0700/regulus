import Foundation

/// RegulusCore 给出的中文词条（IUCN 等级、罕见度）按界面语言显示，译文是 Localizable.xcstrings 里手动加的条目
/// Show a Chinese term from RegulusCore (IUCN category, rarity tier) in the UI language; the translations
/// are manual entries in Localizable.xcstrings.
func localizedCoreText(_ text: String) -> String {
    Bundle.main.localizedString(forKey: text, value: nil, table: nil)
}
