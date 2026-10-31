import RegulusCore
import SwiftUI

/// 主窗口：左侧照片库 / 文件夹，右侧缩略图网格或单张预览 / Main window: library and folders on the left, the grid or a preview on the right.
struct MainView: View {
    @Bindable var library: LibraryModel
    let importModel: ImportModel
    @Bindable var updates: UpdateModel
    @AppStorage("thumbnailSize") private var thumbnailSize = 220.0

    var body: some View {
        NavigationSplitView {
            Sidebar(library: library)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detail
                .navigationTitle(library.previewPhoto?.name ?? library.title)
                .navigationSubtitle("\(library.visiblePhotos.count) 张照片")
                .toolbar {
                    if #available(macOS 26, *) {
                        // macOS 26 会给工具栏项加一个圆角玻璃背景，这里不要 / macOS 26 wraps toolbar items in a glass capsule; hide it
                        ToolbarItem(placement: .navigation) { navigationItem }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .navigation) { navigationItem }
                    }
                    // 分析时进度条放在正中间 / the progress bar sits in the middle while analysing
                    if let progress = library.analysis {
                        ToolbarItem(placement: .principal) {
                            AnalysisProgressBar(progress: progress) { library.cancelAnalysis() }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        // 放进一个项里统一加左右留白，免得图标贴着工具栏的胶囊边缘
                        // One item with side padding, so the icons don't touch the toolbar capsule's edges
                        HStack(spacing: 6) {
                            AnalysisButton(library: library, tasks: .rate, systemImage: "star")
                            AnalysisButton(library: library, tasks: .identify, systemImage: "bird")
                            AnalysisButton(library: library, tasks: .all, systemImage: "sparkles")
                        }
                        .padding(.horizontal, 12)
                    }
                    // 胶囊右侧再空一格，不贴着窗口右边缘 / one more gap after the capsule, away from the window's right edge
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                }
        }
        .frame(minWidth: 900, minHeight: 560)
        .alert("提示", isPresented: Binding(get: { library.alertMessage != nil },
                                           set: { if !$0 { library.alertMessage = nil } })) {
            Button("好") { library.alertMessage = nil }
        } message: {
            Text(library.alertMessage ?? "")
        }
        .sheet(isPresented: $library.isImportPresented) {
            ImportView(model: importModel) { library.isImportPresented = false }
        }
        // 导入面板开着时先不弹，关掉后再显示 / held back while the import sheet is open, shown once it closes
        .sheet(isPresented: Binding(get: { updates.isPresented && !library.isImportPresented },
                                    set: { if !$0 { updates.close() } }),
               onDismiss: { updates.didDismiss() }) {
            UpdateView(model: updates, canInstall: !library.isAnalyzing && !importModel.isTransferring)
        }
        .task { await updates.checkAutomatically() }
        .onChange(of: importModel.destination, initial: true) {
            library.load(root: importModel.destination)
        }
        .onChange(of: importModel.phase) { _, phase in
            guard phase == .finished else { return }
            library.load(root: importModel.destination)
            library.showImported(importModel.importedURLs)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if importModel.destination == nil {
            ContentUnavailableView {
                Label("尚未设置照片库", systemImage: "photo.stack")
            } description: {
                Text("导入照片时选择的文件夹就是照片库。")
            } actions: {
                Button("导入照片…") { library.isImportPresented = true }
            }
        } else if let error = library.loadError {
            ContentUnavailableView("无法读取照片库", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if library.snapshot == nil && library.isLoading {
            ProgressView("正在读取照片库…")
        } else if let photo = library.previewPhoto {
            // 视频铺满主窗口，不显示胶片栏 / videos fill the main window, without the filmstrip
            if photo.isVideo {
                VideoPreview(library: library, photo: photo)
            } else {
                VStack(spacing: 0) {
                    PhotoPreview(library: library, photo: photo)
                    Divider()
                    Filmstrip(library: library, current: photo.url)
                }
            }
        } else if library.visiblePhotos.isEmpty {
            ContentUnavailableView("没有照片", systemImage: "photo",
                                   description: Text("可以通过「文件 › 导入…」（⇧⌘I）导入照片。"))
        } else {
            PhotoGrid(library: library, side: thumbnailSize)
        }
    }

    /// 预览时是返回按钮（Esc 也可以），否则是缩略图大小滑块 / The Back button (or Esc) while previewing, else the size slider.
    @ViewBuilder
    private var navigationItem: some View {
        if library.previewPhoto != nil {
            Button { library.closePreview() } label: {
                Label("返回", systemImage: "chevron.backward")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut(.cancelAction)
            .help("返回网格（Esc）")
        } else {
            sizeSlider
        }
    }

    private var sizeSlider: some View {
        Slider(value: $thumbnailSize, in: 120...480) {
            Text("缩略图大小")
        } minimumValueLabel: {
            Image(systemName: "minus").font(.caption).foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: "plus").font(.caption).foregroundStyle(.secondary)
        }
        .labelsHidden()
        .frame(width: 150)
        // 左侧多留一些，「−」不贴着侧边栏 / more room on the left so − doesn't hug the sidebar
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .help("缩略图大小")
    }
}
