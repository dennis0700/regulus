import AppKit
import Foundation
import RegulusCore

/// 侧边栏文件夹：添加、移除、排序、固定、新建、移到废纸篓
/// Sidebar folders: adding, removing, ordering, pinning, creating and trashing.
extension LibraryModel {
    /// 把文件夹加到侧边栏并重新扫描。之前移除的照片库子文件夹会恢复；已在照片库或已添加文件夹之内的、
    /// 以及包含照片库的会被忽略，避免照片重复出现
    /// Add folders to the sidebar and rescan. A previously removed library subfolder is restored; ones already
    /// inside the library or an added folder, or containing the library, are ignored so no photo shows up twice.
    func addFolders(_ urls: [URL]) {
        guard let root else { return }
        for url in urls.map(\.standardizedFileURL) {
            if excludedFolders.contains(where: { $0.path == url.path }) {
                excludedFolders.removeAll { $0.path == url.path }
                continue
            }
            let inLibrary = Self.isSameOrInside(url, root)
                && !excludedFolders.contains { Self.isSameOrInside(url, $0) }
            let covered = inLibrary || addedFolders.contains { Self.isSameOrInside(url, $0) }
            // 新文件夹包含了已添加的文件夹时，用它替换掉那些 / a new folder that contains added ones replaces them
            if !covered && !Self.isSameOrInside(root, url) {
                addedFolders.removeAll { Self.isSameOrInside($0, url) }
                addedFolders.append(url)
            }
        }
        load(root: root)
    }

    /// 从侧边栏移除文件夹（不会删除磁盘上的文件）：手动添加的直接去掉，照片库的子文件夹记下并在扫描时跳过
    /// Remove a folder from the sidebar (files on disk are untouched): an added folder is dropped, a library subfolder
    /// is remembered and skipped when scanning.
    func removeFolder(_ url: URL) {
        if addedFolders.contains(where: { $0.path == url.path }) {
            addedFolders.removeAll { $0.path == url.path }
        } else {
            excludedFolders.append(url)
        }
        if case let .folder(selected) = sidebarSelection, Self.isSameOrInside(selected, url) { sidebarSelection = .all }
        pinnedFolders.remove(url.path)
        folderOrder.removeAll { $0 == url.path }
        load(root: root)
    }

    /// 侧边栏顶层文件夹（照片库根目录和手动添加的），按保存的顺序 / Top-level sidebar folders (the library root and the
    /// added ones), in saved order.
    var topLevelFolders: [FolderNode] {
        ordered(snapshot?.folders ?? [])
    }

    /// 同级文件夹按保存的顺序排；没排过的保持原顺序（扫描顺序或按名称），排在后面
    /// Siblings in saved order; unordered ones keep their original order (scan or name order), after the ordered ones.
    func ordered(_ siblings: [FolderNode]) -> [FolderNode] {
        siblings.enumerated().sorted {
            (folderOrder.firstIndex(of: $0.element.url.path) ?? folderOrder.count, $0.offset)
                < (folderOrder.firstIndex(of: $1.element.url.path) ?? folderOrder.count, $1.offset)
        }.map(\.element)
    }

    func isPinned(_ url: URL) -> Bool {
        pinnedFolders.contains(url.path)
    }

    /// 固定或取消固定位置：只是标记，文件夹留在原地 / Fix or unfix the position: a mark only; the folder stays put.
    func togglePin(_ url: URL) {
        if pinnedFolders.remove(url.path) == nil { pinnedFolders.insert(url.path) }
    }

    /// 拖拽排序；固定位置的文件夹不动，也不会被挤开 / Drag reordering; folders with a fixed position neither move
    /// nor get pushed aside.
    func moveFolders(from source: IndexSet, to destination: Int) {
        saveOrder(FixedPositions.move(topLevelFolders, from: source, to: destination) { isPinned($0.url) })
    }

    /// 拖拽排序某个文件夹的子文件夹 / Drag reordering of a folder's subfolders.
    func moveSubfolders(of parent: FolderNode, from source: IndexSet, to destination: Int) {
        var children = ordered(parent.children)
        children.move(fromOffsets: source, toOffset: destination)
        saveOrder(children)
    }

    /// 记下一组同级文件夹的新顺序：只比较同级，所以把它们挪到列表末尾即可，其他层级的顺序不受影响
    /// Record the new order of one set of siblings: only siblings are compared, so moving them to the end of the
    /// list is enough and other levels keep their order.
    private func saveOrder(_ siblings: [FolderNode]) {
        let paths = siblings.map(\.url.path)
        folderOrder = folderOrder.filter { !paths.contains($0) } + paths
    }

    /// 能否从侧边栏移除：手动添加的文件夹，或照片库根目录下的一级子文件夹（根目录本身不行）
    /// Removable from the sidebar: an added folder, or a direct child of the library root (not the root itself).
    func canRemoveFolder(_ url: URL) -> Bool {
        addedFolders.contains { $0.path == url.path } || url.deletingLastPathComponent().path == root?.path
    }

    /// 在 parent 里新建文件夹并选中它。名称不能为空、不能以「.」开头（隐藏文件夹扫描不到），也不能含「/」「:」
    /// Create a folder inside parent and select it. The name must not be empty, start with "." (hidden folders are not
    /// scanned), or contain "/" or ":".
    func createFolder(named rawName: String, in parent: URL) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            alertMessage = String(localized: "文件夹名称不能为空、不能以「.」开头，也不能包含「/」或「:」。")
            return
        }
        let url = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = String(localized: "「\(name)」已经存在。")
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            alertMessage = String(localized: "无法新建文件夹：\(error.localizedDescription)")
            return
        }
        // 以前从侧边栏移除过同名文件夹的话，不再跳过它 / if a folder of this name was removed from the sidebar, stop skipping it
        excludedFolders.removeAll { $0.path == url.path }
        sidebarSelection = .folder(url)
        load(root: root)
    }

    /// 能否把文件夹移到废纸篓：照片库根目录不行，免得整个照片库被一键移走
    /// Whether a folder can be moved to the Trash: not the library root, so the whole library can't go in one click.
    func canTrashFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.path != root?.standardizedFileURL.path
    }

    /// 把文件夹连同里面的照片移到废纸篓（可以在 Finder 里「放回原处」）；手动添加的文件夹同时从侧边栏去掉
    /// Move a folder and its photos to the Trash (Finder can "Put Back"); an added folder also leaves the sidebar.
    func moveFolderToTrash(_ url: URL) {
        guard canTrashFolder(url) else { return }
        Task {
            do {
                try await NSWorkspace.shared.recycle([url])
            } catch {
                alertMessage = String(localized: "无法把「\(url.lastPathComponent)」移到废纸篓：\(error.localizedDescription)")
                return
            }
            recentImport.removeAll { Self.isSameOrInside($0.url, url) }
            if addedFolders.contains(where: { $0.path == url.path }) {
                // 同时清掉侧边栏里的记录并重新扫描 / also clears its sidebar entries and rescans
                removeFolder(url)
            } else {
                if case let .folder(selected) = sidebarSelection, Self.isSameOrInside(selected, url) { sidebarSelection = .all }
                load(root: root)
            }
        }
    }

    private static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        return path == folderPath || path.hasPrefix(folderPath + "/")
    }
}
