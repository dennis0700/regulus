import RegulusCore
import SwiftUI

/// 侧边栏底部的鸟种信息：名录中文名、英文名、学名，目科属，IUCN 等级和罕见度
/// Species info at the bottom of the sidebar: checklist names, taxonomy, IUCN category and rarity.
struct SpeciesPanel: View {
    let info: SpeciesInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.zh).font(.title3.weight(.semibold))
            if !info.en.isEmpty { Text(info.en).font(.callout) }
            Text(info.sci).font(.callout).italic().foregroundStyle(.secondary)
            let taxonomy = [info.order, info.family, info.genus].filter { !$0.isEmpty }
            if !taxonomy.isEmpty {
                Text(taxonomy.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let code = info.iucn, let title = info.iucnTitle.map(localizedCoreText) {
                    Text("\(code) \(title)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(code == "VU" ? .black : .white)
                        .background(Self.iucnColor(code), in: RoundedRectangle(cornerRadius: 4))
                        .help("IUCN 红色名录等级")
                }
                if let tier = info.rarityTier.map(localizedCoreText), let rarity = info.rarity {
                    Text("\(tier) \(rarity, specifier: "%.1f")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("GBIF 全球罕见度（0–100，越高越少见）")
                }
            }
            if !info.inChina {
                Text("未收录于《中国鸟类名录》2026 版").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
        .accessibilityElement(children: .combine)
    }

    /// IUCN 等级的颜色：越濒危越红；无危绿；未评估、数据缺乏灰 / IUCN colours: redder when more threatened.
    private static func iucnColor(_ code: String) -> Color {
        switch code {
        case "CR", "EW", "EX": .red
        case "EN": .orange
        case "VU": .yellow
        case "NT": .mint
        case "LC": .green
        default: .gray
        }
    }
}
