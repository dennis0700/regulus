import Foundation

/// 照片库里的一张照片或一段视频 / One photo or video in the library.
public struct LibraryPhoto: Sendable, Hashable, Identifiable {
    public let url: URL
    /// 扫描时的文件修改时间；文件被改写（如外部软件还在写入）后会变，界面据此重新加载缩略图
    /// Modification time at scan; it changes when the file is rewritten (e.g. still being written by another app),
    /// so the UI reloads the thumbnail.
    public let modified: Date?
    public var id: URL { url }

    public init(url: URL, modified: Date? = nil) {
        self.url = url
        self.modified = modified
    }

    /// 不带扩展名的文件名 / File name without extension.
    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var isRaw: Bool { PhotoLibrary.rawExtensions.contains(url.pathExtension.lowercased()) }
    /// 视频只能预览，不能分析、评分或打旗标（见 `RatingFile.canWrite`）/ Videos can only be previewed, not analysed,
    /// rated or flagged (see `RatingFile.canWrite`).
    public var isVideo: Bool { MediaKind(fileName: url.lastPathComponent) == .video }
}

/// 侧边栏里的一个文件夹 / A folder in the sidebar.
public struct FolderNode: Sendable, Hashable, Identifiable {
    public let url: URL
    /// 含所有子文件夹在内的照片和视频数 / Photo and video count including all subfolders.
    public let count: Int
    public let children: [FolderNode]
    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

/// 一次扫描得到的照片库内容 / The library contents from one scan.
public struct LibrarySnapshot: Sendable {
    public let root: URL
    /// 按路径自然排序（同 Finder，DSC2 在 DSC10 前）/ Sorted by path in natural order (as Finder: DSC2 before DSC10).
    public let photos: [LibraryPhoto]
    /// 照片库根目录本身（第一个），后面接手动添加的文件夹 / The library root itself (first), followed by the added folders.
    public let folders: [FolderNode]

    /// 某个文件夹（含子文件夹）里的照片 / Photos in a folder, including its subfolders.
    ///
    /// # Examples
    /// ```
    /// let snapshot = try PhotoLibrary.scan(URL(fileURLWithPath: "/Photos"))
    /// let day = snapshot.photos(in: URL(fileURLWithPath: "/Photos/2026/2026-10-24"))
    /// ```
    public func photos(in folder: URL) -> [LibraryPhoto] {
        let prefix = folder.standardizedFileURL.path + "/"
        return photos.filter { $0.url.path.hasPrefix(prefix) }
    }
}

/// 扫描照片库文件夹 / Scans the library folder.
public enum PhotoLibrary {
    /// `ori` 是奥林巴斯 / OM 高像素模式另存的第一张普通分辨率 RAW（内容就是 ORF）
    /// `ori` is the standard-resolution first frame Olympus / OM save alongside a high-res shot (an ORF inside).
    public static let rawExtensions: Set<String> = ["nef", "arw", "cr3", "orf", "ori", "rw2", "cr2", "dng", "raf"]

    /// 递归列出照片（RAW、JPEG、HEIF）、视频（按扩展名）和文件夹树。只看扩展名和修改时间、不读文件内容，几万张也很快；
    /// 隐藏文件和文件夹、包的内容会被跳过
    /// List photos (RAW, JPEG, HEIF), videos (by extension) and the folder tree recursively. Only extensions and modification
    /// dates are checked (no file reads), so it stays fast for large libraries; hidden items and package contents
    /// are skipped.
    ///
    /// 手动添加的文件夹（可以在照片库之外）也一起扫描，各自作为一个顶层文件夹；暂时不存在的（如外接硬盘未连接）显示为空
    /// Manually added folders (may be outside the library) are scanned too, each as a top-level folder;
    /// ones that are currently missing (e.g. an unplugged drive) show up empty.
    ///
    /// excludedFolders 里的文件夹（及其内容）不会被扫描，用于从侧边栏移除照片库自带的子文件夹
    /// Folders in excludedFolders (and their contents) are skipped; used to remove library subfolders from the sidebar.
    ///
    /// # Examples
    /// ```
    /// let snapshot = try PhotoLibrary.scan(URL(fileURLWithPath: "/Photos"),
    ///                                      addedFolders: [URL(fileURLWithPath: "/Volumes/Disk/Birds")])
    /// print(snapshot.photos.count, snapshot.folders.map(\.name))
    /// ```
    ///
    /// - Throws: 照片库或已添加的文件夹无法遍历、读不了属性时 / when the library or an added folder cannot be
    ///   enumerated or its items' attributes cannot be read.
    public static func scan(_ root: URL, addedFolders: [URL] = [], excludedFolders: [URL] = []) throws -> LibrarySnapshot {
        let root = root.standardizedFileURL
        let added = addedFolders.map(\.standardizedFileURL)
        let excluded = Set(excludedFolders.map(\.standardizedFileURL.path))
        var photos: [LibraryPhoto] = []
        var directories: [URL] = []
        try walk(root, excluded: excluded, photos: &photos, directories: &directories)
        for folder in added where FileManager.default.fileExists(atPath: folder.path) {
            try walk(folder, excluded: excluded, photos: &photos, directories: &directories)
        }
        photos.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        let nodes = tree(roots: [root] + added, directories: directories, photos: photos)
        return LibrarySnapshot(root: root, photos: photos, folders: nodes)
    }

    /// 递归收集一个文件夹下的照片和子文件夹 / Collect photos and subfolders under one folder.
    private static func walk(_ folder: URL, excluded: Set<String>, photos: inout [LibraryPhoto],
                             directories: inout [URL]) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        for case let url as URL in walker {
            let url = url.standardizedFileURL
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                if excluded.contains(url.path) {
                    walker.skipDescendants()
                } else {
                    directories.append(url)
                }
            } else if MediaScanner.importExtensions.contains(url.pathExtension.lowercased()) {
                photos.append(LibraryPhoto(url: url, modified: values.contentModificationDate))
            }
        }
    }

    /// 由目录和照片列表为每个根建树，计数包含子文件夹 / Build a tree per root; counts include subfolders.
    static func tree(roots: [URL], directories: [URL], photos: [LibraryPhoto]) -> [FolderNode] {
        var children: [URL: [URL]] = [:]
        for directory in directories {
            children[directory.deletingLastPathComponent().standardizedFileURL, default: []].append(directory)
        }
        var direct: [URL: Int] = [:]
        for photo in photos {
            direct[photo.url.deletingLastPathComponent().standardizedFileURL, default: 0] += 1
        }
        func build(_ folder: URL) -> FolderNode {
            let subfolders = (children[folder] ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map(build)
            let count = (direct[folder] ?? 0) + subfolders.reduce(0) { $0 + $1.count }
            return FolderNode(url: folder, count: count, children: subfolders)
        }
        return roots.map(build)
    }
}
