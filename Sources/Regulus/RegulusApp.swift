import AppKit
import RegulusCore
import SwiftUI

@main
struct RegulusApp: App {
    // 在 App 层创建，保证整个进程只有一份（视图的初始化会被 SwiftUI 反复调用）
    // Created at the App level so there is exactly one of each (SwiftUI re-runs view initializers).
    @State private var importModel = ImportModel()
    @State private var library = LibraryModel()
    @State private var updates = UpdateModel()

    var body: some Scene {
        Window("Regulus", id: "main") {
            MainView(library: library, importModel: importModel, updates: updates)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updates.check() }
            }
            CommandGroup(replacing: .newItem) {
                Button("导入…") { library.isImportPresented = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) { pasteboardCommands }
            CommandGroup(after: .toolbar) {
                Button("重新载入照片库") { library.load(root: importModel.destination) }
                    .keyboardShortcut("r")
                    .disabled(importModel.destination == nil)
            }
            CommandMenu("照片") {
                // 先「评分」筛掉废片，再「识别」剩下的；照片不多时直接「评分+识别」
                // Rate first to weed out rejects, then identify the rest; with few photos, do both at once
                ForEach([AnalysisTasks.rate, .identify, .all], id: \.self) { tasks in
                    Button(library.selection.isEmpty ? "\(tasks.title)（全部）" : "\(tasks.title)（所选）") { library.analyzeTargets(tasks) }
                        .keyboardShortcut(Self.analysisShortcut(tasks), modifiers: [.command, .shift])
                        .disabled(library.isAnalyzing || library.analysisTargets.isEmpty)
                }
                Button("停止分析") { library.cancelAnalysis() }
                    .keyboardShortcut(".")
                    .disabled(!library.isAnalyzing)
                Divider()
                // 与 Lightroom / Photomator 一致：数字键 1–5 评分，0 清除 / As in Lightroom / Photomator: 1–5 rate, 0 clears
                Button("清除评分") { library.setUserRating(nil) }
                    .keyboardShortcut("0", modifiers: [])
                    .disabled(!canRate)
                ForEach(Array(RatingFile.range), id: \.self) { stars in
                    Button(String(repeating: "★", count: stars)) { library.setUserRating(stars) }
                        .keyboardShortcut(KeyEquivalent(Character("\(stars)")), modifiers: [])
                        .disabled(!canRate)
                }
                Divider()
                // 与 Lightroom 一致：P 旗标、U 无旗标、X 排除 / As in Lightroom: P pick, U unflag, X reject
                Button("旗标") { library.setFlag(.picked) }
                    .keyboardShortcut("p", modifiers: [])
                    .disabled(!canRate)
                Button("无旗标") { library.setFlag(nil) }
                    .keyboardShortcut("u", modifiers: [])
                    .disabled(!canRate)
                Button("排除") { library.setFlag(.rejected) }
                    .keyboardShortcut("x", modifiers: [])
                    .disabled(!canRate)
            }
        }

        Settings {
            SettingsView(importModel: importModel, library: library, updates: updates)
        }
    }

    /// ⇧⌘E 评分、⇧⌘B 识别、⇧⌘R 评分+识别 / ⇧⌘E rate, ⇧⌘B identify, ⇧⌘R both.
    private static func analysisShortcut(_ tasks: AnalysisTasks) -> KeyEquivalent {
        switch tasks {
        case .rate: "e"
        case .identify: "b"
        default: "r"
        }
    }

    /// 有选中照片且没有打开导入面板时才能评分、设旗标（快捷键没有修饰键，避免面板里误触）
    /// Rating and flagging need a selection and no import sheet (the keys have no modifier, so avoid stray presses there).
    private var canRate: Bool {
        !library.selection.isEmpty && !library.isImportPresented
    }

    /// 剪切/拷贝/粘贴照常交给响应链；⌘A 在文本框里全选文字，否则全选照片
    /// Cut/copy/paste go to the responder chain as usual; ⌘A selects text in a text field, otherwise all photos.
    @ViewBuilder
    private var pasteboardCommands: some View {
        Button("剪切") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
            .keyboardShortcut("x")
        Button("拷贝") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
            .keyboardShortcut("c")
        Button("粘贴") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
            .keyboardShortcut("v")
        Divider()
        Button("全选") {
            if NSApp.keyWindow?.firstResponder is NSText {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            } else {
                library.selectAll()
            }
        }
        .keyboardShortcut("a")
        Button("取消选择") { library.clearSelection() }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(library.selection.isEmpty)
    }
}
