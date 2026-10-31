import AppKit
import Foundation
import RegulusCore

/// 照片的选择、框选、右键对象与预览
/// Photo selection, marquee, context-menu targets and preview.
extension LibraryModel {
    /// 点击一张照片：单击只选它，⌘ 点击加入/移出，⇧ 点击把与上次点击之间的区间加入选择
    /// Click a photo: plain click selects only it, ⌘-click toggles it, ⇧-click adds the range from the anchor.
    func click(_ photo: LibraryPhoto, modifiers: NSEvent.ModifierFlags) {
        let url = photo.url
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let from = visiblePhotos.firstIndex(where: { $0.url == anchor }),
           let to = visiblePhotos.firstIndex(where: { $0.url == url }) {
            selection.formUnion(visiblePhotos[min(from, to)...max(from, to)].map(\.url))
            return
        }
        if modifiers.contains(.command) {
            if selection.remove(url) == nil { selection.insert(url) }
        } else {
            selection = [url]
        }
        selectionAnchor = url
    }

    func selectAll() {
        selection = Set(visiblePhotos.map(\.url))
    }

    /// 方向键移动选框：从上次点击（或移动到）的照片挪 delta 张，只选中它；没有选择时选第一张；越界不动
    /// Arrow-key move: step delta photos from the last clicked (or moved-to) photo and select only it; picks the
    /// first photo when nothing is selected; does nothing past either end.
    ///
    /// - Returns: 新选中的照片，用来滚动到可见处 / The newly selected photo, to scroll it into view.
    func moveSelection(by delta: Int) -> URL? {
        let photos = visiblePhotos
        let current = selectionAnchor.flatMap { anchor in photos.firstIndex { $0.url == anchor } }
            ?? photos.firstIndex { selection.contains($0.url) }
        let target = current.map { $0 + delta } ?? 0
        guard photos.indices.contains(target) else { return nil }
        let url = photos[target].url
        selection = [url]
        selectionAnchor = url
        return url
    }

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    /// 开始框选：记下当前选择作为基准，按修饰键决定合并方式
    /// Start a marquee: remember the current selection as the base and pick the mode from the modifier keys.
    func beginMarquee(modifiers: NSEvent.ModifierFlags) {
        marqueeBase = selection
        marqueeMode = modifiers.contains(.command) ? .toggle : (modifiers.contains(.shift) ? .add : .replace)
    }

    /// 框选过程中更新选择 / Update the selection while the marquee is being dragged.
    func updateMarquee(hits: Set<URL>) {
        selection = marqueeMode.apply(base: marqueeBase, hits: hits)
    }

    /// 右键一张照片时要处理的照片：它在选择里就是整个选择（按显示顺序），否则只有它，与 Finder 一致
    /// Photos a right-click acts on: the whole selection (in display order) if the photo is in it, else just that photo,
    /// as in Finder.
    func contextTargets(for photo: LibraryPhoto) -> [URL] {
        selection.contains(photo.url) ? visiblePhotos.map(\.url).filter(selection.contains) : [photo.url]
    }

    /// 右键菜单上显示的张数（不用算出整个列表）/ Count shown in the context menu (without building the list).
    func contextTargetCount(for photo: LibraryPhoto) -> Int {
        selection.contains(photo.url) ? selection.count : 1
    }

    /// 信息面板显示的照片：预览中的那张，否则唯一选中的那张 / The photo shown in the info panel: the previewed one,
    /// else the single selected one.
    var inspectedPhoto: LibraryPhoto? {
        if let previewPhoto { return previewPhoto }
        guard selection.count == 1, let url = selection.first else { return nil }
        return visiblePhotos.first { $0.url == url }
    }

    /// 预览中的照片；照片库重新扫描后不在当前列表里了就为 nil，回到网格
    /// The previewed photo; nil (back to the grid) once a rescan drops it from the current list.
    var previewPhoto: LibraryPhoto? {
        previewURL.flatMap { url in visiblePhotos.first { $0.url == url } }
    }

    /// 进入预览，只选中这一张，数字键评分作用于它 / Open the preview and select only this photo, so digit keys rate it.
    func openPreview(_ photo: LibraryPhoto) {
        selection = [photo.url]
        selectionAnchor = photo.url
        previewURL = photo.url
    }

    func closePreview() {
        previewURL = nil
    }

    /// 预览上一张（-1）/ 下一张（+1），到头了就不动 / Preview the previous (-1) / next (+1) photo; stops at the ends.
    func stepPreview(by delta: Int) {
        if let photo = previewNeighbour(delta) { openPreview(photo) }
    }

    func canStepPreview(by delta: Int) -> Bool {
        previewNeighbour(delta) != nil
    }

    /// 预览上一个（-1）/ 下一个（+1）视频，跳过中间的照片；到头了就不动
    /// Preview the previous (-1) / next (+1) video, skipping photos in between; stops at the ends.
    func stepVideo(by delta: Int) {
        if let video = videoNeighbour(delta) { openPreview(video) }
    }

    func canStepVideo(by delta: Int) -> Bool {
        videoNeighbour(delta) != nil
    }

    private func videoNeighbour(_ delta: Int) -> LibraryPhoto? {
        let photos = visiblePhotos
        guard let url = previewURL, let index = photos.firstIndex(where: { $0.url == url }) else { return nil }
        let after = delta > 0 ? Array(photos[(index + 1)...]) : Array(photos[..<index].reversed())
        return after.first(where: \.isVideo)
    }

    private func previewNeighbour(_ delta: Int) -> LibraryPhoto? {
        let photos = visiblePhotos
        guard let url = previewURL, let index = photos.firstIndex(where: { $0.url == url }),
              photos.indices.contains(index + delta) else { return nil }
        return photos[index + delta]
    }
}
