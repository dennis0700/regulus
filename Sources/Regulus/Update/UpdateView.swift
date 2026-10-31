import RegulusCore
import SwiftUI

/// 更新面板：检查结果、更新说明、下载进度 / The update sheet: check result, release notes, download progress.
struct UpdateView: View {
    let model: UpdateModel
    /// 分析或导入进行中不能更新：安装会退出 App / No updating during an analysis or import: installing quits the app.
    let canInstall: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.state {
            case .idle, .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在检查更新…")
                }
                buttons { Button("取消") { model.close() }.keyboardShortcut(.cancelAction) }
            case .upToDate:
                Text("Regulus \(model.currentVersion) 已是最新版本。")
                buttons { Button("好") { model.close() }.keyboardShortcut(.defaultAction) }
            case let .failed(message):
                Text(message).fixedSize(horizontal: false, vertical: true)
                buttons { Button("好") { model.close() }.keyboardShortcut(.defaultAction) }
            case let .available(release):
                available(release)
            case let .downloading(release, fraction):
                Text("正在下载 Regulus \(release.version)…").font(.headline)
                HStack {
                    ProgressView(value: fraction)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Text(fraction < 1 ? "下载完成后 Regulus 会退出，换成新版本后重新打开。" : "正在校验并准备安装…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                buttons { Button("取消") { model.cancel() }.disabled(fraction >= 1) }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(model.isDownloading)
    }

    @ViewBuilder
    private func available(_ release: AppRelease) -> some View {
        Text("Regulus \(release.version) 可以更新了").font(.headline)
        Text("当前版本 \(model.currentVersion)。下载 \(ByteCountFormatter.string(fromByteCount: release.size, countStyle: .file))，装好后自动重新打开。")
            .foregroundStyle(.secondary)
        if !release.notes.isEmpty {
            ScrollView {
                Text(notes(release.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            // 面板按内容定高，只给最大高度时滚动区会被压成 0 / the sheet sizes to its content, which collapses a
            // scroll view that only has a maximum height
            .frame(height: 160)
        }
        Link("在 GitHub 上查看", destination: release.page)
        if !canInstall {
            Text("分析或导入进行中，结束后再更新。")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        buttons {
            Button("以后") { model.close() }.keyboardShortcut(.cancelAction)
            Button("下载并重新打开") { model.install(release) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canInstall)
        }
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
    }

    /// 只渲染行内 Markdown（粗体、链接等），保留换行；标题和列表符号原样显示
    /// Render inline Markdown only (bold, links, …) and keep line breaks; headings and bullets show as typed.
    private func notes(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
