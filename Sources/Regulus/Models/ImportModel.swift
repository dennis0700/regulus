import Foundation
import ImageCaptureCore
import Observation
import RegulusCore

/// 导入界面的状态；真正的工作都在 RegulusCore 里，这里只负责把它接到界面上
/// State of the import screen; the real work lives in RegulusCore, this only wires it to the UI.
@MainActor @Observable
final class ImportModel {
    enum Phase: Equatable {
        case idle, scanning, ready, importing, deleting, finished
    }

    /// 三种来源 / The three kinds of import source.
    enum SourceKind: CaseIterable, Identifiable {
        case folder, card, camera
        var id: Self { self }
        var title: String {
            switch self {
            case .folder: String(localized: "文件夹")
            case .card: String(localized: "存储卡")
            case .camera: String(localized: "相机 (PTP)")
            }
        }
    }

    /// 当前选中的具体来源 / The concrete source currently selected.
    enum Selection: Equatable {
        case folder(URL)
        case card(URL)
        case camera(ICCameraDevice)
    }

    private static let destinationKey = "importDestination"

    private(set) var phase = Phase.idle
    private(set) var kind = SourceKind.card
    private(set) var selection: Selection?
    private(set) var cards: [URL] = []
    let cameraBrowser = CameraBrowser()
    private(set) var files: [any ImportItem] = []
    private(set) var progress: ImportProgress?
    private(set) var report: ImportReport?
    /// 导入后删除源文件的结果；没勾选时为 nil / Result of deleting the sources; nil when the option was off.
    private(set) var deletion: DeletionReport?
    /// 导入后删除存储卡 / 相机里的原文件。每次换来源或重新开始都恢复为关闭，不记住
    /// Delete originals on the card or camera after importing. Reset to off for every new source or reset; not remembered.
    var deletesSourceAfterImport = false
    private(set) var errorMessage: String?
    private(set) var destination: URL? = UserDefaults.standard.string(forKey: ImportModel.destinationKey)
        .map { URL(fileURLWithPath: $0) }

    private var importTask: Task<ImportReport, Error>?
    /// 只有来源是 PTP 相机时才有 / Present only when the source is a PTP camera.
    private var cameraSession: CameraSession?
    /// 每次选择或清除来源加一，用来丢弃过期的扫描结果 / Bumped per selection or clear to drop stale scan results.
    private var generation = 0

    var cameras: [ICCameraDevice] { cameraBrowser.cameras }
    var isCameraSource: Bool { cameraSession != nil }
    var isBusy: Bool { phase == .scanning || phase == .importing || phase == .deleting }
    /// 导入或删除进行中，不能关闭面板 / Importing or deleting; the sheet must stay open.
    var isTransferring: Bool { phase == .importing || phase == .deleting }
    /// 只有存储卡和相机能导入后删除，文件夹来源不提供，免得误删电脑里的文件
    /// Only cards and cameras offer delete-after-import; folder sources don't, to avoid deleting files on the Mac.
    var canDeleteSource: Bool { kind != .folder }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var canStart: Bool { phase == .ready && destination != nil && !files.isEmpty }

    /// 这次导入后照片库里对应的文件（已复制和已存在跳过的，不含失败的）/ Library files from this import (copied and
    /// skipped, not failed).
    var importedURLs: [URL] {
        (report?.results ?? []).compactMap { result in
            if case .failed = result.outcome { nil } else { result.destination }
        }
    }

    /// 失败的文件名和原因 / Names and reasons of failed files.
    var failures: [(name: String, reason: String)] {
        (report?.results ?? []).compactMap { result in
            if case let .failed(reason) = result.outcome { (result.name, reason) } else { nil }
        }
    }

    func refreshCards() {
        cards = MediaScanner.cameraCards()
        dropRemovedSelection()
    }

    func setDestination(_ url: URL) {
        destination = url
        UserDefaults.standard.set(url.path, forKey: Self.destinationKey)
    }

    /// 切换来源类型，清掉上一种类型下的选择 / Switch source kind and clear the previous selection.
    func setKind(_ newKind: SourceKind) {
        guard newKind != kind, !isBusy else { return }
        clearSelection()
        kind = newKind
    }

    func chooseFolder(_ url: URL) {
        scan(url, as: .folder(url))
    }

    func chooseCard(_ url: URL) {
        scan(url, as: .card(url))
    }

    /// 选定 PTP 相机：打开会话并读取文件列表 / Pick a PTP camera: open a session and read its catalog.
    func chooseCamera(_ camera: ICCameraDevice) {
        let current = beginSelection(.camera(camera))
        let session = CameraSession(camera: camera)
        cameraSession = session
        Task {
            do {
                finishSelection(current, files: try await session.open())
            } catch {
                failSelection(current, error)
            }
        }
    }

    /// 选中的存储卡被拔出、相机被断开时清掉选择（导入中和导入完成后不动，保留结果）
    /// Clear the selection when its card or camera goes away (left alone while importing or after finishing).
    func dropRemovedSelection() {
        guard phase == .scanning || phase == .ready else { return }
        switch selection {
        case let .card(url) where !cards.contains(url):
            clearSelection()
        case let .camera(camera) where !cameras.contains(camera):
            clearSelection()
        default:
            break
        }
    }

    private func scan(_ url: URL, as newSelection: Selection) {
        let current = beginSelection(newSelection)
        Task {
            do {
                let found = try await Task.detached { try MediaScanner.scan(url) }.value
                finishSelection(current, files: found)
            } catch {
                failSelection(current, error)
            }
        }
    }

    /// 开始导入；勾选了删除原文件时，导入完成后只删除已安全进照片库的源文件
    /// Start importing; with delete-after-import on, only sources safely in the library are deleted once it finishes.
    func startImport() {
        guard canStart, let destination else { return }
        let importer = PhotoImporter(destination: destination)
        let files = files
        let deletesSource = deletesSourceAfterImport && canDeleteSource
        errorMessage = nil
        progress = nil
        deletion = nil
        phase = .importing
        let work = Task.detached(priority: .userInitiated) {
            try await importer.run(files: files) { update in
                Task { @MainActor in self.progress = update }
            }
        }
        importTask = work
        Task {
            do {
                let finished = try await work.value
                report = finished
                // 取消或出错时不会走到这里，也就不会删除任何文件 / never reached on cancel or error, so nothing is deleted
                if deletesSource {
                    phase = .deleting
                    deletion = await PhotoImporter.deleteImportedSources(files, report: finished)
                }
            } catch is CancellationError {
                errorMessage = String(localized: "导入已取消，已复制的照片保留在目标文件夹中。")
            } catch {
                errorMessage = "\(error)"
            }
            importTask = nil
            phase = .finished
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    /// 回到初始状态并重新检测存储卡，准备导入下一张卡（保留来源类型）
    /// Back to the start and re-detect cards for the next one (keeps the source kind).
    func reset() {
        clearSelection()
        refreshCards()
    }

    private func clearSelection() {
        closeCamera()
        generation += 1
        selection = nil
        files = []
        progress = nil
        report = nil
        deletion = nil
        deletesSourceAfterImport = false
        errorMessage = nil
        phase = .idle
    }

    private func beginSelection(_ newSelection: Selection) -> Int {
        closeCamera()
        generation += 1
        selection = newSelection
        files = []
        report = nil
        deletion = nil
        // 换来源时恢复为不删除，每次都要明确勾选 / back to "don't delete" for every new source; it must be ticked each time
        deletesSourceAfterImport = false
        errorMessage = nil
        phase = .scanning
        return generation
    }

    private func finishSelection(_ current: Int, files found: [any ImportItem]) {
        guard current == generation else { return }
        files = found
        phase = .ready
    }

    private func failSelection(_ current: Int, _ error: Error) {
        guard current == generation else { return }
        closeCamera()
        selection = nil
        errorMessage = String(localized: "无法读取来源：\(error.localizedDescription)")
        phase = .idle
    }

    private func closeCamera() {
        cameraSession?.close()
        cameraSession = nil
    }
}
