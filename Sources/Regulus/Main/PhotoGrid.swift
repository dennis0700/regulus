import AppKit
import RegulusCore
import SwiftUI

struct PhotoGrid: View {
    let library: LibraryModel
    let side: Double
    /// 当前已渲染的格子在网格内容坐标系里的位置（懒加载，滚出很远的格子会被移除）
    /// Frames of the cells currently rendered, in the grid content's coordinates (lazy: far-off cells are removed).
    @State private var frames: [URL: CGRect] = [:]
    @State private var marquee: CGRect?
    @FocusState private var isFocused: Bool
    /// 按 Delete 后等待确认移到废纸篓的照片 / Photos awaiting confirmation to go to the Trash after pressing Delete.
    @State private var pendingTrash: [URL]?
    // nonisolated：要在几何回调（Sendable 闭包）里使用 / nonisolated so the geometry callback (a Sendable closure) can use it
    nonisolated private static let space = "photoGrid"

    /// 按 2 倍（视网膜屏）取图，并归到 512 / 1024 两档，拖动滑块时可以复用缓存
    /// Fetch at 2x (Retina), snapped to 512 / 1024 so dragging the slider reuses the cache.
    private var pixelSize: Int { side * 2 <= 512 ? 512 : 1024 }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    grid(viewportHeight: viewport.size.height)
                }
                // 网格有焦点时方向键移动选框；焦点在侧边栏时方向键照常切换侧边栏
                // Arrow keys move the selection while the grid has focus; with the sidebar focused they work there as usual
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let delta = switch press.key {
                    case .leftArrow: -1
                    case .rightArrow: 1
                    case .upArrow: -columns
                    default: columns
                    }
                    if let url = library.moveSelection(by: delta) { proxy.scrollTo(url) }
                    return .handled
                }
                // Delete（⌫ 或 ⌦）：确认后把所选照片移到废纸篓 / Delete (⌫ or ⌦): move the selection to the Trash after confirming
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    let urls = library.visiblePhotos.map(\.url).filter(library.selection.contains)
                    guard !urls.isEmpty else { return .ignored }
                    pendingTrash = urls
                    return .handled
                }
                .confirmationDialog(trashTitle, isPresented: Binding(get: { pendingTrash != nil },
                                                                     set: { if !$0 { pendingTrash = nil } })) {
                    Button("移到废纸篓", role: .destructive) {
                        if let urls = pendingTrash { library.moveToTrash(urls) }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("可以在 Finder 的废纸篓里「放回原处」。")
                }
                .onAppear { isFocused = true }
            }
        }
    }

    private var trashTitle: String {
        let count = pendingTrash?.count ?? 0
        return count == 1 ? String(localized: "把「\(pendingTrash?.first?.lastPathComponent ?? "")」移到废纸篓？")
            : String(localized: "把 \(count) 张照片移到废纸篓？")
    }

    /// 每行几张：数已渲染格子里与最上面一行底边对齐的（同一行贴底对齐；懒加载渲染的最上一行总是满的）
    /// Photos per row: rendered cells whose bottom lines up with the top row's (rows are bottom-aligned; the top
    /// rendered row is always full).
    private var columns: Int {
        guard let top = frames.values.map(\.maxY).min() else { return 1 }
        return max(frames.values.filter { abs($0.maxY - top) < 1 }.count, 1)
    }

    private func grid(viewportHeight: CGFloat) -> some View {
        // 同一行贴底对齐：有竖拍时这一行高一些，横拍的文件名仍和它排在同一条线上
        // Rows are bottom-aligned: a row with a portrait is taller, and the landscape labels still line up with it
        LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side), spacing: 20, alignment: .bottom)],
                  spacing: 24) {
            ForEach(library.visiblePhotos) { photo in
                PhotoCell(photo: photo, side: side, pixelSize: pixelSize, cache: library.thumbnails,
                          isSelected: library.selection.contains(photo.url),
                          userStars: library.userRating(for: photo),
                          flag: library.flag(for: photo),
                          speciesName: library.speciesInfo(for: photo)?.zh)
                    .id(photo.url)
                    .onTapGesture {
                        isFocused = true
                        library.click(photo, modifiers: NSEvent.modifierFlags)
                        // 用系统的点击计数判断双击，单击不用等双击超时 / use the system click count so single clicks don't wait
                        if NSApp.currentEvent?.clickCount == 2 { library.openPreview(photo) }
                    }
                    // 拖到侧边栏的文件夹上移动；拖已选中的照片时带上整个选择（内容在开始拖时才算）
                    // Drag onto a sidebar folder to move; dragging a selected photo carries the whole selection
                    // (the payload is computed only when the drag starts)
                    .draggable(library.dragPayload(for: photo)) {
                        DragBadge(count: library.contextTargetCount(for: photo))
                    }
                    .contextMenu { PhotoContextMenu(library: library, photo: photo) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                        frames[photo.url] = $0
                    }
                    .onDisappear { frames[photo.url] = nil }
            }
        }
        .padding(24)
        // 至少铺满可视区域，照片少时下方空白处也能点击和框选 / fill the viewport so empty space below is clickable
        .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
        .contentShape(Rectangle())
        // 点空白处取消选择 / clicking empty space clears the selection
        .onTapGesture {
            isFocused = true
            library.clearSelection()
        }
        .simultaneousGesture(marqueeGesture)
        .overlay(alignment: .topLeading) { marqueeOverlay }
        .coordinateSpace(.named(Self.space))
    }

    /// 拖动画框：普通拖动替换选择，⇧ 加选，⌘ 反选 / Drag a box: plain replaces, ⇧ adds, ⌘ toggles.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if marquee == nil {
                    // 和 Finder 一样：从照片上开始拖是拖照片，只有从空白处开始才画框
                    // As in Finder: dragging from a photo drags the photo; only a drag from empty space draws a box
                    guard !frames.values.contains(where: { $0.contains(value.startLocation) }) else { return }
                    library.beginMarquee(modifiers: NSEvent.modifierFlags)
                }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x),
                                  height: abs(value.location.y - value.startLocation.y))
                marquee = rect
                library.updateMarquee(hits: Set(frames.filter { $0.value.intersects(rect) }.keys))
            }
            .onEnded { _ in
                marquee = nil
            }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                .frame(width: marquee.width, height: marquee.height)
                .offset(x: marquee.minX, y: marquee.minY)
                .allowsHitTesting(false)
        }
    }
}

/// 拖照片时跟着鼠标的小标签 / The little badge that follows the pointer while dragging photos.
struct DragBadge: View {
    let count: Int

    var body: some View {
        Label(count == 1 ? "1 张照片" : "\(count) 张照片", systemImage: "photo.on.rectangle")
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}
