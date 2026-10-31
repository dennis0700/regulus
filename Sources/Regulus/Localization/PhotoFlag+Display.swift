import Foundation
import RegulusCore

extension PhotoFlag {
    /// 界面上的名称；与菜单项「旗标」「排除」同字，用单独的键以便分别翻译 / Display name; the same words as the
    /// Flag / Reject menu items, under separate keys so they can be translated differently.
    var title: String {
        switch self {
        case .picked: String(localized: "flag.picked", defaultValue: "旗标")
        case .rejected: String(localized: "flag.rejected", defaultValue: "排除")
        }
    }

    var systemImage: String {
        switch self {
        case .picked: "flag.fill"
        case .rejected: "xmark.circle.fill"
        }
    }
}
