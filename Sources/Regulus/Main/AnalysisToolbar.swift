import RegulusCore
import SwiftUI

/// 工具栏右侧的一个分析按钮：只显示图标，悬停提示要处理的照片；分析进行中变灰。
/// 含识别的任务在有地区名录时先弹出拍摄地点（默认为设置里的），可只为这一次改成别处
/// One analysis button on the toolbar's trailing side: icon only, the tooltip says which photos it will process;
/// greyed out while an analysis runs. Tasks that identify first pop up the shooting region (the default from
/// Settings) when the checklist is installed, so it can be changed for this run only.
struct AnalysisButton: View {
    let library: LibraryModel
    let tasks: AnalysisTasks
    let systemImage: String
    @State private var choosingRegion = false

    var body: some View {
        let count = library.analysisTargets.count
        Button {
            if tasks.contains(.identify), FileManager.default.fileExists(atPath: library.regionsURL.path) {
                choosingRegion = true
            } else {
                library.analyzeTargets(tasks)
            }
        } label: {
            // 无障碍仍读出按钮名称 / VoiceOver still reads the button name
            Label(tasks.title, systemImage: systemImage).labelStyle(.iconOnly)
        }
        .help(library.selection.isEmpty ? String(localized: "\(tasks.title)当前显示的 \(count) 张照片。")
              : String(localized: "\(tasks.title)所选的 \(count) 张照片。"))
        .disabled(library.isAnalyzing || count == 0)
        .popover(isPresented: $choosingRegion, arrowEdge: .bottom) {
            RegionPopover(url: library.regionsURL) { region in
                choosingRegion = false
                library.analyzeTargets(tasks, region: region)
            } onCancel: {
                choosingRegion = false
            }
        }
    }
}

/// 工具栏正中：分析的进度和停止按钮，只在分析时出现 / Toolbar centre: analysis progress and Stop, shown only while running.
struct AnalysisProgressBar: View {
    let progress: LibraryModel.AnalysisProgress
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if progress.loadingModels {
                ProgressView().controlSize(.small)
                Text("正在加载模型…")
            } else {
                Text(progress.tasks.title)
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 160)
                    .accessibilityLabel("\(progress.tasks.title)进度")
                Text("\(progress.done)/\(progress.total)").monospacedDigit().foregroundStyle(.secondary)
            }
            Button(action: onStop) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("停止（⌘.）")
            .accessibilityLabel("停止")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .fixedSize()
    }
}
