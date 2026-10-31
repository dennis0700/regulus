import AppKit
import Foundation
import RegulusCore

/// 拖拽、移动照片和移到废纸篓
/// Dragging, moving photos and moving them to the Trash.
extension LibraryModel {
    /// 拖拽带的内容：一行一个照片路径 / Drag payload: one photo path per line.
    func dragPayload(for photo: LibraryPhoto) -> String {
        contextTargets(for: photo).map(\.path).joined(separator: "\n")
    }

    /// 从拖拽内容里取出照片库里的照片；别处拖来的文字一律忽略
    /// Library photos from a drag payload; text dragged in from elsewhere is ignored.
    func draggedPhotos(_ payloads: [String]) -> [URL] {
        let known = Set(snapshot?.photos.map(\.url.path) ?? [])
        return payloads.flatMap { $0.split(separator: "\n") }.map(String.init).filter(known.contains)
            .map { URL(fileURLWithPath: $0) }
    }

    /// 把照片移到 folder（星级、旗标和鸟种都写在照片文件里，本来就跟着走）。
    /// 分析进行中不能移动：分析任务拿着旧路径
    /// Move photos into folder (stars, flags and species live in the files and move with them). Not allowed during
    /// an analysis, which holds the old paths.
    func movePhotos(_ urls: [URL], to folder: URL) {
        guard let root = snapshot?.root, !urls.isEmpty else { return }
        guard !isAnalyzing else {
            alertMessage = String(localized: "分析进行中，等分析结束后再移动照片。")
            return
        }
        Task {
            let results = await Task.detached(priority: .userInitiated) { PhotoMover.move(urls, to: folder) }.value
            let moved = results.compactMap { result in result.destination.map { (from: result.source, to: $0) } }
            relocateRecentImport(moved)
            let failed = results.filter { $0.error != nil }
            if !failed.isEmpty {
                let names = Self.nameList(failed.map(\.source.lastPathComponent))
                alertMessage = String(localized: "有 \(failed.count) 张照片没能移动：\(names)\n\(failed[0].error ?? "")")
            }
            load(root: root)
        }
    }

    /// 把「最近导入」里移动过的照片改到新路径 / Point moved photos in "recent import" at their new paths.
    private func relocateRecentImport(_ moves: [(from: URL, to: URL)]) {
        guard !moves.isEmpty else { return }
        let destinations = Dictionary(moves.map { ($0.from.path, $0.to) }, uniquingKeysWith: { first, _ in first })
        recentImport = recentImport.map { photo in destinations[photo.url.path].map { LibraryPhoto(url: $0) } ?? photo }
    }

    /// 移到废纸篓（可以在 Finder 里「放回原处」），完成后重新扫描照片库
    /// Move to the Trash (Finder can "Put Back"), then rescan the library.
    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            do {
                try await NSWorkspace.shared.recycle(urls)
            } catch {
                // 部分成功时也会到这里，下面照样重新扫描 / also reached on partial success; the rescan below still runs
                alertMessage = String(localized: "有照片没能移到废纸篓：\(error.localizedDescription)")
            }
            recentImport.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
            load(root: root)
        }
    }
}
