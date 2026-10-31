import AppKit
import Foundation
import Observation
import RegulusCore

/// 从 GitHub 更新 App 的状态：检查、下载，装好后退出并由后台脚本换新版重新打开
/// State of updating from GitHub: check, download, then quit so a background script swaps in the new version and
/// reopens it.
@MainActor @Observable
final class UpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        /// 下载进度 0–1；到 1 之后是校验和解压 / Download progress 0–1; verifying and unzipping follow at 1.
        case downloading(AppRelease, Double)
        case failed(String)
    }

    private static let autoCheckKey = "checksForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"

    private(set) var state = State.idle
    /// 是否显示更新面板 / Whether the update sheet is shown.
    var isPresented = false
    /// 启动时自动检查（默认开）/ Check at launch (on by default).
    var checksAutomatically = UserDefaults.standard.object(forKey: UpdateModel.autoCheckKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Self.autoCheckKey) }
    }
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 新版已就绪，面板关掉后退出 / The new version is ready; quit once the sheet has closed.
    @ObservationIgnored private var quitsAfterDismiss = false

    var isDownloading: Bool { task != nil }

    /// 启动时调用：开启了自动检查且距上次超过一天才查；只有发现新版本才弹出面板，出错不打扰
    /// Called at launch: checks only when enabled and a day has passed; shows the sheet only for a new version and
    /// stays quiet on errors.
    func checkAutomatically() async {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard checksAutomatically, Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        guard let release = try? await AppUpdate.fetchLatest(),
              AppUpdate.isNewer(release.version, than: currentVersion),
              state == .idle else { return }
        state = .available(release)
        isPresented = true
    }

    /// 菜单「检查更新…」：打开面板显示检查结果 / The Check for Updates… menu item: show the result in the sheet.
    func check() {
        isPresented = true
        guard !isDownloading else { return }
        state = .checking
        Task {
            do {
                let release = try await AppUpdate.fetchLatest()
                state = AppUpdate.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch {
                state = .failed(String(localized: "无法检查更新：\(Self.message(error))"))
            }
        }
    }

    /// 下载、校验并解压新版，然后退出 App；取消时回到「有新版本」/ Download, verify and unzip, then quit; on cancel,
    /// back to "available".
    func install(_ release: AppRelease) {
        guard task == nil else { return }
        state = .downloading(release, 0)
        task = Task {
            defer { task = nil }
            do {
                let zip = try await AppUpdate.download(release) { fraction in
                    Task { @MainActor in self.report(fraction, for: release) }
                }
                defer { try? FileManager.default.removeItem(at: zip) }
                try Task.checkCancellation()
                state = .downloading(release, 1)
                let app = Bundle.main.bundleURL
                let newApp = try await Task.detached { try AppUpdate.prepare(zip, release: release, replacing: app) }.value
                try AppUpdate.installAfterExit(newApp, replacing: app)
                // 窗口挂着面板时 AppKit 会拒绝退出，所以先关面板，等 didDismiss 再退出
                // AppKit refuses to quit while a window has a sheet, so close it and quit in didDismiss
                quitsAfterDismiss = true
                isPresented = false
            } catch is CancellationError {
                state = .available(release)
            } catch let error as URLError where error.code == .cancelled {
                state = .available(release)
            } catch {
                state = .failed(String(localized: "更新失败：\(Self.message(error))"))
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// 面板关闭后由视图调用 / Called by the view once the sheet has closed.
    func didDismiss() {
        if quitsAfterDismiss { NSApp.terminate(nil) }
    }

    func close() {
        guard !isDownloading else { return }
        isPresented = false
        state = .idle
    }

    /// 晚到的进度（下载已结束或已取消）忽略 / Ignore progress arriving after the download ended or was cancelled.
    private func report(_ fraction: Double, for release: AppRelease) {
        guard case .downloading(release, let current) = state, current < 1 else { return }
        state = .downloading(release, fraction)
    }

    private static func message(_ error: Error) -> String {
        (error as? RegulusError)?.description ?? error.localizedDescription
    }
}
