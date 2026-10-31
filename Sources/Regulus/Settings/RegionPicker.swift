import Foundation
import RegulusCore
import SwiftUI

/// 拍摄地区：eBird 国家、省州代码，空串为不限 / The shooting region: eBird country and province codes, empty for none.
struct ShootingRegion: Equatable {
    var country = ""
    var province = ""

    /// 「设置 › 识别」里保存默认地区的 UserDefaults 键 / UserDefaults keys of the default in Settings › Identification.
    static let countryKey = "regionCountry"
    static let provinceKey = "regionProvince"

    /// 默认地区 / The default region.
    static var saved: ShootingRegion {
        ShootingRegion(country: UserDefaults.standard.string(forKey: countryKey) ?? "",
                       province: UserDefaults.standard.string(forKey: provinceKey) ?? "")
    }
}

/// 国家和省 / 州两个选择器，换国家时省州回到「全境」；没有名录时只有「不限」
/// The country and province pickers; changing the country resets the province to "entire country"; without a
/// checklist only "any" is offered.
struct RegionPicker: View {
    let checklist: RegionChecklist?
    @Binding var region: ShootingRegion

    var body: some View {
        Picker("国家或地区", selection: $region.country) {
            Text("不限").tag("")
            ForEach(sorted(checklist?.countries ?? [])) { Text(verbatim: name($0)).tag($0.code) }
        }
        .onChange(of: region.country) { region.province = "" }
        Picker("省 / 州", selection: $region.province) {
            Text("全境").tag("")
            ForEach(sorted(provinces)) { Text(verbatim: name($0)).tag($0.code) }
        }
        .disabled(provinces.isEmpty)
    }

    private var provinces: [Region] {
        checklist?.countries.first { $0.code == region.country }?.regions ?? []
    }

    /// 中文界面用中文名，否则用英文名 / Chinese names in the Chinese UI, English otherwise.
    private func name(_ region: Region) -> String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? region.zh : region.en
    }

    private func sorted(_ regions: [Region]) -> [Region] {
        regions.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
}

/// 点「识别」或「评分+识别」时弹出：默认是设置里的地区，可只为这一次改成别处
/// Shown on Identify or Rate + Identify: starts at the default region from Settings, which can be changed for this
/// run only.
struct RegionPopover: View {
    let url: URL
    let onStart: (ShootingRegion) -> Void
    let onCancel: () -> Void
    @State private var checklist: RegionChecklist?
    @State private var region = ShootingRegion.saved

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    RegionPicker(checklist: checklist, region: $region)
                } header: {
                    Text("拍摄地点")
                } footer: {
                    Text("只用于这一次识别；默认地点在「设置 › 识别」里修改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            // 分组表单会滚动，要给高度；内容放得下，不让它滚 / a grouped form scrolls and needs a height; it fits, so no scrolling
            .frame(height: 160)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("开始") { onStart(region) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 380)
        .task { checklist = try? RegionChecklist(url: url) }
    }
}
