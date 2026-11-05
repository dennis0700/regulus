import RegulusCore
import SwiftUI

/// 更正鸟种的输入框：输入中文名、拼音（全拼或首字母，如 "xte" → 小天鹅）、英文名或学名，从名录里选一个写进照片；
/// ↑↓ 选择，回车确定，Esc 取消
/// The species correction sheet: type a Chinese name, pinyin (full or initials, e.g. "xte" -> 小天鹅), English or
/// scientific name and pick one from the checklist to write into the photos; ↑↓ to choose, Return to apply, Esc to
/// cancel.
struct SpeciesCorrectionSheet: View {
    let library: LibraryModel
    let targets: [URL]
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(targets.count == 1 ? "更正鸟种" : "更正 \(targets.count) 张照片的鸟种").font(.headline)
            if let current = currentName {
                Text("当前：\(current)").font(.callout).foregroundStyle(.secondary)
            }
            TextField("中文名、拼音或首字母（如 xte）、英文名", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onChange(of: query) { highlighted = 0 }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onSubmit(apply)
            results
            HStack {
                Spacer()
                Button("取消") { library.speciesCorrectionTargets = nil }
                    .keyboardShortcut(.cancelAction)
                Button("更正", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ids.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isFieldFocused = true }
    }

    @ViewBuilder
    private var results: some View {
        let ids = ids
        ScrollViewReader { proxy in
            List(Array(ids.enumerated()), id: \.element) { index, id in
                if let info = library.speciesInfo(id) {
                    row(info, isHighlighted: index == highlighted)
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = index }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            highlighted = index
                            apply()
                        })
                }
            }
            .listStyle(.plain)
            .frame(height: 260)
            .overlay {
                if library.speciesSearch == nil {
                    ProgressView()
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty && ids.isEmpty {
                    Text("名录里没有找到").foregroundStyle(.secondary)
                }
            }
            .onChange(of: highlighted) {
                if ids.indices.contains(highlighted) { proxy.scrollTo(ids[highlighted]) }
            }
        }
    }

    private func row(_ info: SpeciesInfo, isHighlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(info.zh).fontWeight(.medium)
            Text(info.en).foregroundStyle(isHighlighted ? .primary : .secondary).lineLimit(1)
            Spacer()
            Text(info.sci).italic().font(.caption).foregroundStyle(isHighlighted ? .primary : .secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private var ids: [Int] {
        library.speciesSearch?.ids(matching: query, preferred: library.regionalSpecies) ?? []
    }

    /// 只有一张时显示它现在的鸟名 / The current species name, when correcting a single photo.
    private var currentName: String? {
        guard targets.count == 1, let url = targets.first else { return nil }
        return library.titles[url]
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let count = ids.count
        guard count > 0 else { return .handled }
        highlighted = min(max(highlighted + delta, 0), count - 1)
        return .handled
    }

    private func apply() {
        let ids = ids
        guard ids.indices.contains(highlighted), let info = library.speciesInfo(ids[highlighted]) else { return }
        library.applySpeciesCorrection(info)
    }
}
