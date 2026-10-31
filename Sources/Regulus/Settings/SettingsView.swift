import AppKit
import RegulusCore
import SwiftUI

/// 设置窗口（App 菜单 › 设置…，⌘,）/ The Settings window (App menu › Settings…, ⌘,).
struct SettingsView: View {
    let importModel: ImportModel
    let library: LibraryModel
    let updates: UpdateModel

    var body: some View {
        TabView {
            GeneralSettingsView(importModel: importModel, updates: updates, isAnalyzing: library.isAnalyzing)
                .tabItem { Label("通用", systemImage: "gearshape") }
            RegionSettingsView(url: library.regionsURL, installed: library.modelDownload.installed)
                .tabItem { Label("识别", systemImage: "bird") }
            ModelSettingsView(model: library.modelDownload, isAnalyzing: library.isAnalyzing)
                .tabItem { Label("模型", systemImage: "square.and.arrow.down") }
        }
        .frame(width: 520)
    }
}

/// 通用：界面语言、导入目标文件夹、自动检查更新 / General: the UI language, the import destination and automatic
/// update checks.
private struct GeneralSettingsView: View {
    let importModel: ImportModel
    @Bindable var updates: UpdateModel
    /// 分析或导入进行中不重新打开 / No relaunching during an analysis or import.
    let isAnalyzing: Bool
    @State private var pickingDestination = false
    @State private var language = AppLanguage.saved

    var body: some View {
        // 与「模型」页一样用分组表单：标题在左、控件在右 / A grouped form like the Models tab: titles left, controls right
        Form {
            Section {
                Picker("语言", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { language.save() }
                if language != AppLanguage.atLaunch {
                    LabeledContent("重新打开 Regulus 后生效。") {
                        Button("立即重新打开") { try? AppLanguage.relaunch() }
                            .disabled(isAnalyzing || importModel.isTransferring)
                            .help(isAnalyzing || importModel.isTransferring ? "分析或导入进行中，结束后再重新打开" : "")
                    }
                }
            }
            Section {
                LabeledContent {
                    Button(importModel.destination == nil ? "选择文件夹…" : "更改…") { pickingDestination = true }
                        .disabled(importModel.isBusy)
                } label: {
                    Text("导入目标文件夹")
                        .help("这个文件夹就是照片库。照片和视频会按「类型 / 年月日」整理（如 Raw/20261025、Video/20261025），原文件不会被修改；只有导入时勾选「导入后删除」才会删除。")
                    Text(importModel.destination?.path ?? String(localized: "尚未选择"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(importModel.destination?.path ?? "")
                }
            }
            Section {
                Toggle("启动时自动检查更新", isOn: $updates.checksAutomatically)
                LabeledContent("当前版本") { Text(verbatim: updates.currentVersion) }
            }
        }
        .formStyle(.grouped)
        // 分组表单本身会滚动，要给高度 / a grouped form scrolls, so it needs a height
        .frame(height: 260)
        .fileImporter(isPresented: $pickingDestination, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { importModel.setDestination(url) }
        }
    }
}

/// 识别：选拍摄的国家和省州，识鸟时只在当地的 eBird 名录里挑（先省州、再国家）
/// Identification: pick the shooting country and province; species ID then only picks from the local eBird lists
/// (the province first, then the country).
private struct RegionSettingsView: View {
    let url: URL
    /// 已装好的下载项；变化时（如刚下载了名录）重新读取 / Installed downloads; reread the checklist when it changes
    /// (e.g. the checklist was just downloaded).
    let installed: Set<String>
    @State private var checklist: RegionChecklist?
    @AppStorage(ShootingRegion.countryKey) private var country = ""
    @AppStorage(ShootingRegion.provinceKey) private var province = ""

    var body: some View {
        Form {
            Section {
                RegionPicker(checklist: checklist, region: Binding(
                    get: { ShootingRegion(country: country, province: province) },
                    set: { country = $0.country; province = $0.province }))
            } footer: {
                if checklist == nil {
                    Text("还没有地区名录，请在「设置 › 模型」中下载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 150)
        .disabled(checklist == nil)
        .task(id: installed) { checklist = try? RegionChecklist(url: url) }
    }
}

/// 模型：从 superpicky-coreml 的 GitHub Release 下载 / Models: download from the superpicky-coreml GitHub release.
private struct ModelSettingsView: View {
    let model: ModelDownloadModel
    /// 分析中不替换模型 / Models are not replaced during an analysis.
    let isAnalyzing: Bool

    var body: some View {
        Form {
            Section {
                if model.isLoadingManifest {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在读取模型清单…").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.assets) { asset in
                    // 标题是用途，副标题是模型名和大小 / title is the purpose; subtitle the name and size
                    LabeledContent {
                        status(asset)
                    } label: {
                        Text(Self.purpose(asset.name))
                        Text(verbatim: "\(asset.name) · "
                             + ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))
                    }
                }
            } header: {
                Text("检测、识鸟和评分用的 Core ML 模型来自 [superpicky-coreml](\(ModelDownload.releasePage.absoluteString))。")
            }
            Section {
                controls
                if let message = model.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                // 与模型行一样：标题下面一行小字是路径 / like the model rows: the path is the small line under the title
                LabeledContent {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.directory]) }
                        .disabled(!FileManager.default.fileExists(atPath: model.directory.path))
                } label: {
                    Text("存储位置")
                    Text(model.directory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.directory.path)
                }
            }
        }
        .formStyle(.grouped)
        // 分组表单本身会滚动，不给高度时设置窗口会把它压扁 / a grouped form scrolls, so without a height the Settings
        // window squeezes it
        .frame(height: 500)
        .task { await model.load() }
    }

    /// 模型的用途；清单里没有说明，按名称对应，认不出的显示名称本身
    /// What a model is for; the manifest has no description, so map by name and fall back to the name itself.
    private static func purpose(_ name: String) -> String {
        switch name {
        case "yolo11l-seg": String(localized: "鸟的检测与分割")
        case "birdtrace": String(localized: "鸟种识别")
        case "topiq": String(localized: "美学评分")
        case "keypoint": String(localized: "眼睛和鸟喙定位")
        case "flight": String(localized: "飞版识别")
        case "regions": String(localized: "各地区鸟种名录")
        default: name
        }
    }

    @ViewBuilder
    private func status(_ asset: ModelAsset) -> some View {
        if model.installed.contains(asset.name) {
            Label("已安装", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if model.progress?.name == asset.name {
            Label("下载中", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        } else if model.outdated.contains(asset.name) {
            Label("有新版本", systemImage: "arrow.up.circle")
                .foregroundStyle(.orange)
        } else {
            Label("未安装", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if let progress = model.progress {
            HStack {
                ProgressView(value: progress.fraction)
                Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Button("取消") { model.cancel() }
            }
        } else if model.assets.isEmpty {
            Button("重试") { Task { await model.load() } }
                .disabled(model.isLoadingManifest)
        } else if model.missing.isEmpty {
            Text("模型已全部安装，均为最新版本。")
                .foregroundStyle(.secondary)
        } else {
            let size = model.missing.reduce(0) { $0 + $1.size }
            Button("下载缺少或有更新的模型（\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))）") {
                model.downloadMissing()
            }
            .disabled(model.isDownloading || isAnalyzing)
            .help(isAnalyzing ? "分析进行中，结束后再下载" : "")
        }
    }
}
