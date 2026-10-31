import Foundation
import RegulusCore

extension AnalysisTasks {
    /// 按钮和进度上的名称；与「评分」菜单同字，用单独的键以便分别翻译 / Name on the buttons and the progress; the
    /// same word as the Rating menu, under separate keys so they can be translated differently.
    var title: String {
        switch self {
        case .rate: String(localized: "tasks.rate", defaultValue: "评分")
        case .identify: String(localized: "tasks.identify", defaultValue: "识别")
        default: String(localized: "tasks.all", defaultValue: "评分+识别")
        }
    }
}
