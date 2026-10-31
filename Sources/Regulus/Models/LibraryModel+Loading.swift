import Foundation
import RegulusCore

/// 读取照片库、监听外部改动
/// Loading the library and watching for outside changes.
extension LibraryModel {
    /// 重新扫描照片库并读取照片文件里的星级、旗标和标题。root 为 nil 表示还没设置
    /// Rescan the library and read the stars, flags and titles from the files. A nil root means it is not set yet.
    func load(root: URL?) {
        generation += 1
        let current = generation
        self.root = root
        loadError = nil
        watch(root)
        guard let root else {
            snapshot = nil
            flags = [:]
            userRatings = [:]
            titles = [:]
            isLoading = false
            return
        }
        isLoading = true
        let addedFolders = addedFolders
        let excludedFolders = excludedFolders
        Task {
            do {
                let scanned = try await Task.detached(priority: .userInitiated) {
                    try PhotoLibrary.scan(root, addedFolders: addedFolders, excludedFolders: excludedFolders)
                }.value
                guard current == generation else { return }
                snapshot = scanned
                dropMissingFolderSelection()
                selection = selection.filter { url in scanned.photos.contains { $0.url == url } }
                // 先显示网格，星级、旗标和标题随后从文件里读出来（每张约 3ms）/ show the grid first; stars, flags and
                // titles follow from the files
                let urls = scanned.photos.filter { !$0.isVideo }.map(\.url)
                let tags = await Task.detached(priority: .userInitiated) { RatingFile.readAll(urls) }.value
                guard current == generation else { return }
                var ratings: [URL: Int] = [:], flagged: [URL: PhotoFlag] = [:], named: [URL: String] = [:]
                for (url, tag) in tags {
                    ratings[url] = tag.rating
                    flagged[url] = tag.flag
                    named[url] = tag.title
                }
                // 还在排队写入的评分和旗标以设置的值为准，否则会一张张跳回旧值；评分会覆盖排除，排除会清掉星级
                // ratings and flags still queued for writing keep the value set, otherwise they flip back photo by
                // photo; a rating replaces a reject, and a reject clears the stars
                for (url, stars) in pendingRatings {
                    ratings[url] = stars == 0 ? nil : stars
                    if flagged[url] == .rejected { flagged[url] = nil }
                }
                for (url, flag) in pendingFlags {
                    flagged[url] = flag
                    if flag == .rejected { ratings[url] = nil }
                }
                userRatings = ratings
                flags = flagged
                titles = named
            } catch {
                guard current == generation else { return }
                snapshot = nil
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// 导入完成后显示这次导入的照片 / Show the photos of the import that just finished.
    func showImported(_ urls: [URL]) {
        recentImport = urls.map { LibraryPhoto(url: $0.standardizedFileURL) }
        sidebarSelection = .recentImport
    }

    /// 照片库或手动添加的文件夹变了才重建监听（每次重新扫描都会调用）
    /// Rebuild the watcher only when the library or the added folders change (called on every rescan).
    private func watch(_ root: URL?) {
        let folders = root.map { [$0] + addedFolders } ?? []
        let paths = folders.map(\.path)
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        watcher = folders.isEmpty ? nil : FolderWatcher(folders) { [weak self] in
            Task { @MainActor in self?.rescanAfterOutsideChange() }
        }
    }

    /// 在 Finder 等 App 外改动了文件或文件夹：重新扫描；分析进行中就等它结束再扫，免得每写一张照片就重扫一次
    /// Files or folders changed outside the app: rescan, or wait for a running analysis to end rather than rescanning
    /// after every photo it writes.
    private func rescanAfterOutsideChange() {
        guard root != nil else { return }
        if isAnalyzing {
            rescanAfterAnalysis = true
        } else {
            load(root: root)
        }
    }

    func rescanIfPending() {
        guard rescanAfterAnalysis else { return }
        rescanAfterAnalysis = false
        load(root: root)
    }

    private func dropMissingFolderSelection() {
        guard case let .folder(url) = sidebarSelection else { return }
        if !FileManager.default.fileExists(atPath: url.path) { sidebarSelection = .all }
    }
}
