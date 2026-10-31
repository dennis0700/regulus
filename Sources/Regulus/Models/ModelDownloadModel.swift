import Foundation
import Observation
import RegulusCore

/// 设置 › 模型 的状态：读取发布清单，下载缺少的模型 / State of Settings › Models: read the release manifest and download
/// the missing models.
@MainActor @Observable
final class ModelDownloadModel {
    /// 当前正在下载的模型和全部下载的总进度（0–1，按字节）/ The model being downloaded and the overall progress
    /// (0–1, by bytes).
    struct Progress: Equatable {
        var name: String
        var fraction: Double
    }

    let directory: URL
    private(set) var assets: [ModelAsset] = []
    /// 已安装且是最新版 / Installed and up to date.
    private(set) var installed: Set<String> = []
    /// 已安装但与清单版本不一致（Release 里有新版本）/ Installed, but not the manifest's version (the release has a
    /// newer one).
    private(set) var outdated: Set<String> = []
    private(set) var isLoadingManifest = false
    private(set) var progress: Progress?
    private(set) var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let onInstalled: @MainActor () -> Void

    /// `onInstalled` 在每个模型装好后调用 / `onInstalled` runs after each model is installed.
    init(directory: URL, onInstalled: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.onInstalled = onInstalled
    }

    var isDownloading: Bool { task != nil }
    /// 要下载的：没装的和有新版本的 / To download: not installed or outdated.
    var missing: [ModelAsset] { assets.filter { !installed.contains($0.name) } }

    /// 读取发布清单（已读过则只刷新安装状态）/ Load the release manifest (if loaded, just refresh what is installed).
    func load() async {
        guard assets.isEmpty else { return refreshInstalled() }
        isLoadingManifest = true
        defer { isLoadingManifest = false }
        do {
            assets = try await ModelDownload.fetchManifest()
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "无法读取模型清单：\(error.localizedDescription)")
        }
        refreshInstalled()
    }

    /// 依次下载并安装缺少或有新版本的模型；出错或取消时停下，已装好的保留
    /// Download and install the missing or outdated models one by one; stops on error or cancel, keeping those installed.
    func downloadMissing() {
        guard task == nil else { return }
        let queue = missing
        let total = Double(queue.reduce(0) { $0 + $1.size })
        guard total > 0 else { return }
        errorMessage = nil
        task = Task {
            var done = 0.0
            for asset in queue {
                guard !Task.isCancelled else { break }
                let base = done
                progress = Progress(name: asset.name, fraction: base / total)
                do {
                    try await install(asset) { fraction in
                        // 晚到的进度（下载已结束）忽略 / ignore progress that arrives after the download ended
                        guard self.progress?.name == asset.name else { return }
                        self.progress?.fraction = (base + fraction * Double(asset.size)) / total
                    }
                } catch is CancellationError {
                    break
                } catch let error as URLError where error.code == .cancelled {
                    break
                } catch {
                    errorMessage = String(localized: "「\(asset.name)」下载失败：\(error.localizedDescription)")
                    break
                }
                done += Double(asset.size)
            }
            progress = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func install(_ asset: ModelAsset, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        let zip = try await ModelDownload.download(asset) { fraction in
            Task { @MainActor in onProgress(fraction) }
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        try Task.checkCancellation()
        let directory = directory
        // 校验和解压要读写几百 MB，放到后台 / hashing and unzipping touch hundreds of MB; keep them off the main actor
        try await Task.detached { try ModelDownload.install(zip, asset: asset, into: directory) }.value
        installed.insert(asset.name)
        outdated.remove(asset.name)
        onInstalled()
    }

    private func refreshInstalled() {
        installed = Set(assets.filter { ModelDownload.isCurrent($0, in: directory) }.map(\.name))
        outdated = Set(assets.filter { ModelDownload.isInstalled($0, in: directory) }.map(\.name)).subtracting(installed)
    }
}
