import RegulusCore
import SwiftUI

/// 单张照片的大图预览：缩放（⌘= ⌘- ⌘0、⌘ + 滚轮、捏合、双击，最大 100%）、放大后拖动平移、旋转（⌘[ ⌘]，只改显示不改文件）、← → 切换
/// Large preview of one photo: zoom (⌘= ⌘- ⌘0, ⌘ + scroll, pinch, double-click; up to 100%), pan when zoomed,
/// rotate (⌘[ ⌘], display only, the file is untouched), ← → to step.
struct PhotoPreview: View {
    let library: LibraryModel
    let photo: LibraryPhoto
    @State private var thumbnail: Thumbnail?
    /// 相对「适合窗口」的倍数 / Zoom relative to fit-to-window.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// 顺时针转了几个 90° / Number of clockwise quarter turns.
    @State private var quarterTurns = 0
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    /// 图片区域的大小 / Size of the image area.
    @State private var viewport: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    private static let zoomStep: CGFloat = 1.5

    /// 适合窗口时，原图一个像素占多少个屏幕物理像素 / Screen device pixels per original pixel at fit-to-window.
    private var fitPixelRatio: CGFloat? {
        guard let thumbnail, viewport.width > 0, viewport.height > 0 else { return nil }
        let turned = quarterTurns % 2 != 0
        // pixelWidth/Height 是原图尺寸（不是显示用的预览图）/ pixelWidth/Height are the original's, not the preview's
        let width = CGFloat(turned ? thumbnail.pixelHeight : thumbnail.pixelWidth)
        let height = CGFloat(turned ? thumbnail.pixelWidth : thumbnail.pixelHeight)
        return min(viewport.width / width, viewport.height / height) * displayScale
    }

    /// 放大上限 100%：原图一个像素对应屏幕一个物理像素；原图比窗口还小时不放大
    /// Zoom limit at 100%: one original pixel per screen device pixel; no zoom when the original is smaller than the window.
    private var maxScale: CGFloat {
        fitPixelRatio.map { max(1 / $0, 1) } ?? 1
    }

    /// 相对原图的缩放百分比 / Zoom as a percentage of the original.
    private var zoomPercent: Int {
        Int(((fitPixelRatio ?? 1) * scale * 100).rounded())
    }

    var body: some View {
        let speciesName = library.speciesInfo(for: photo)?.zh
        let userStars = library.userRating(for: photo)
        VStack(spacing: 12) {
            GeometryReader { geometry in
                if let thumbnail {
                    image(thumbnail, in: geometry.size)
                        .overlay { badges(in: fitSize(thumbnail, in: geometry.size), stars: userStars) }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
            .clipped()
            // ⌘ + 滚轮向上放大一档、向下缩小一档 / ⌘ + scroll up zooms in one step, down zooms out one step
            .modifier(ModifierScrollZoom { step in
                setScale(step > 0 ? scale * Self.zoomStep : scale / Self.zoomStep)
            })
            // 鸟种行总是占位，加旗标、评分或识别出鸟种都不会让图片区域变大小
            // the species line always takes room, so flags, stars or a species never resize the image area
            Text(speciesName ?? " ")
                .font(.caption)
                .lineLimit(1)
        }
        .padding(24)
        .toolbar { ToolbarItemGroup(placement: .principal) { controls } }
        // 换照片时恢复适合窗口、不旋转；旧图留着直到新图出来，避免闪一下 / reset on photo change; keep the old image until the new one loads
        .onChange(of: photo.url) {
            setScale(1)
            quarterTurns = 0
        }
        // 按照片（含修改时间）重新取图，外部软件写完文件后会刷新 / keyed on the photo incl. its modification time,
        // so it refreshes once another app finishes writing the file
        .task(id: photo) {
            // 先用 1024 的缩略图快速出图（网格用大格子时已在缓存里），再在后台换成全尺寸图，100% 能看清真实像素；
            // 全尺寸图不进缓存，换照片就释放，免得占太多内存
            // Show a 1024 thumbnail first (already cached when the grid uses large cells), then swap in the full-size
            // image decoded in the background so 100% shows real pixels; it is not cached and is freed on photo change
            thumbnail = await library.thumbnails.thumbnail(for: photo.url, maxPixelSize: 1024)
            let url = photo.url
            if let large = await Task.detached(priority: .userInitiated, operation: {
                ThumbnailCache.makeFullSize(url)
            }).value, !Task.isCancelled {
                thumbnail = large
            }
        }
    }

    /// 适合窗口时图片在屏幕上的宽高；转 90° 时宽高互换，按互换后的比例适配
    /// On-screen size of the image at fit-to-window; a quarter turn swaps width and height, so fit the swapped aspect.
    private func fitSize(_ thumbnail: Thumbnail, in size: CGSize) -> CGSize {
        let aspect = CGFloat(thumbnail.image.width) / CGFloat(max(thumbnail.image.height, 1))
        let fitAspect = quarterTurns % 2 != 0 ? 1 / aspect : aspect
        let fitWidth = min(size.width, size.height * fitAspect)
        return CGSize(width: fitWidth, height: fitWidth / fitAspect)
    }

    /// 和网格一样的角标：左上 RAW、右上星级、左下旗标；贴在适合窗口时的图片四角，不随缩放旋转
    /// Corner badges as in the grid: RAW top-left, stars top-right, flag bottom-left; pinned to the fit-to-window
    /// image corners, unaffected by zoom and rotation.
    private func badges(in fit: CGSize, stars: Int?) -> some View {
        Color.clear
            .frame(width: fit.width, height: fit.height)
            .overlay(alignment: .topLeading) {
                if photo.isRaw { Badge(text: "RAW").padding(8) }
            }
            .overlay(alignment: .topTrailing) {
                if let stars { StarsMark(stars: stars).padding(8) }
            }
            .overlay(alignment: .bottomLeading) {
                if let flag = library.flag(for: photo) { FlagMark(flag: flag).padding(8) }
            }
            .allowsHitTesting(false)
    }

    private func image(_ thumbnail: Thumbnail, in size: CGSize) -> some View {
        let turned = quarterTurns % 2 != 0
        let fit = fitSize(thumbnail, in: size)
        return Image(thumbnail.image, scale: 1, label: Text(photo.name))
            .resizable()
            .frame(width: turned ? fit.height : fit.width, height: turned ? fit.width : fit.height)
            .rotationEffect(.degrees(Double(quarterTurns) * 90))
            .scaleEffect(scale * pinch)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { setScale(scale > 1 ? 1 : 2) }
            .contextMenu { PhotoContextMenu(library: library, photo: photo) }
            .gesture(magnify)
            .simultaneousGesture(pan, including: scale > 1 ? .all : .none)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { setScale(scale * $0.magnification) }
    }

    private var pan: some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { offset = CGSize(width: offset.width + $0.translation.width,
                                       height: offset.height + $0.translation.height) }
    }

    /// 缩放限制在适合窗口到 100% 之间；回到适合窗口时居中 / Zoom is clamped between fit and 100%; back at fit it re-centres.
    private func setScale(_ value: CGFloat) {
        scale = min(max(value, 1), maxScale)
        if scale == 1 { offset = .zero }
    }

    @ViewBuilder
    private var controls: some View {
        Button { library.stepPreview(by: -1) } label: { Label("上一张", systemImage: "chevron.left") }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!library.canStepPreview(by: -1))
            .help("上一张（←）")
        Button { library.stepPreview(by: 1) } label: { Label("下一张", systemImage: "chevron.right") }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!library.canStepPreview(by: 1))
            .help("下一张（→）")
        Button { setScale(scale / Self.zoomStep) } label: { Label("缩小", systemImage: "minus.magnifyingglass") }
            .keyboardShortcut("-")
            .disabled(scale <= 1)
            .help("缩小（⌘- 或 ⌘ + 滚轮向下）")
        Button { setScale(1) } label: { Label("适合窗口", systemImage: "arrow.down.right.and.arrow.up.left") }
            .keyboardShortcut("0")
            .disabled(scale == 1)
            .help("适合窗口（⌘0）")
        Button { setScale(scale * Self.zoomStep) } label: { Label("放大", systemImage: "plus.magnifyingglass") }
            .keyboardShortcut("=")
            .disabled(scale >= maxScale)
            .help("放大（⌘= 或 ⌘ + 滚轮向上），最大 100%")
        Text("\(zoomPercent)%")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 44)
            .accessibilityLabel("缩放 \(zoomPercent)%")
        Button { quarterTurns -= 1 } label: { Label("向左旋转", systemImage: "rotate.left") }
            .keyboardShortcut("[")
            .help("向左旋转（⌘[），只改显示")
        Button { quarterTurns += 1 } label: { Label("向右旋转", systemImage: "rotate.right") }
            .keyboardShortcut("]")
            .help("向右旋转（⌘]），只改显示")
    }
}
