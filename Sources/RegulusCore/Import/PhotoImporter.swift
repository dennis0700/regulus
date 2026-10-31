import CryptoKit
import Foundation

/// 导入失败的原因 / Import failures.
public enum ImportError: Error, Equatable, CustomStringConvertible {
    case notEnoughSpace(needed: Int64, available: Int64)
    case sizeMismatch(name: String, expected: Int64, actual: Int64)

    public var description: String {
        switch self {
        case let .notEnoughSpace(needed, available):
            "目标磁盘空间不足 / not enough space: need \(needed) bytes, \(available) available"
        case let .sizeMismatch(name, expected, actual):
            "\(name) 大小不符 / size mismatch: expected \(expected) bytes, got \(actual)"
        }
    }
}

/// 一个待导入的文件，来源可以是存储卡上的文件，也可以是 PTP 相机里的文件
/// A file to import; it may live on a mounted card or inside a PTP camera.
public protocol ImportItem: Sendable {
    var name: String { get }
    var size: Int64 { get }
    /// 拍摄日期（年月日，相机本地时间）/ Capture date (y/m/d, camera-local).
    var captureDate: DateComponents { get }
    /// 不写盘就能得到的内容 sha256；做不到（如 PTP 相机）时返回 nil
    /// sha256 of the content without writing anything; nil when that is not possible (PTP cameras).
    func contentHash() async throws -> String?
    /// 把内容写到 `part`（调用方已先删掉旧文件）；落盘由 `PhotoImporter` 在改成正式文件名前做
    /// Write the content to `part` (the caller removes any old file first); `PhotoImporter` flushes it before giving
    /// it the real name.
    func stage(to part: URL) async throws
    /// 能否和其他文件同时导入（PTP 相机一次只能下载一个）/ Whether it can be imported alongside other files (a PTP
    /// camera downloads one at a time).
    var importsConcurrently: Bool { get }
    /// 要保留到副本上的创建/修改时间 / Creation/modification dates to keep on the copy.
    func preservedDates() -> [FileAttributeKey: Date]
    /// 删除来源里的原文件；只在确认已安全导入后由 `PhotoImporter.deleteImportedSources` 调用
    /// Delete the original from the source; only called by `PhotoImporter.deleteImportedSources` once it is safely imported.
    func deleteSource() async throws
}

/// 导入进度：已处理几个、共几个，`file` 是刚处理完的文件名
/// Progress: files done out of the total; `file` is the name of the file just finished.
public struct ImportProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let file: String
}

public enum ImportOutcome: Sendable, Equatable {
    /// 复制进照片库；照片库里的同名文件内容不同时，用来源的版本覆盖它
    /// Copied into the library, replacing a same-name library file whose content differs.
    case copied
    /// 照片库里已有同名、同大小、同内容的文件 / The library already has a same-name, same-size, identical file.
    case skippedDuplicate
    case failed(String)
}

public struct ImportResult: Sendable, Equatable {
    public let name: String
    /// 照片库里的对应文件；失败时为 nil / The matching file in the library; nil on failure.
    public let destination: URL?
    public let outcome: ImportOutcome
}

public struct ImportReport: Sendable {
    public let results: [ImportResult]
    public var copied: Int { results.filter { $0.outcome == .copied }.count }
    public var skipped: Int { results.filter { $0.outcome == .skippedDuplicate }.count }
    public var failed: Int { results.count - copied - skipped }
}

/// 导入后删除源文件的结果 / Result of deleting the sources after an import.
public struct DeletionReport: Sendable {
    public let deleted: Int
    public let failures: [(name: String, reason: String)]
}

/// 按类型和日期复制到 `destination/类型/年月日/`（如 `Raw/20261025`），复制后核对大小；导入本身绝不改动或删除源文件，
/// 删除源文件要另外调用 `deleteImportedSources`
/// Copies files to `destination/kind/yyyyMMdd/` (e.g. `Raw/20261025`) and checks each copy's size; importing never
/// touches the source — deleting it is a separate call to `deleteImportedSources`.
///
/// 判重只看目标目录里的同名文件，以来源（存储卡、相机）为准：大小相同时才算哈希比对，内容相同就跳过；
/// 大小或内容不同就用来源的版本原子替换它
/// Duplicates are judged from the same-name file in the destination folder, and the source (card, camera) wins:
/// only a same-size file is hashed, and identical content is skipped; a different size or content is atomically
/// replaced by the source's version.
public struct PhotoImporter: Sendable {
    public let destination: URL
    static let chunkSize = 4 * 1024 * 1024
    /// 同时导入的文件数：macOS 的 exFAT（FSKit）单个读请求延迟高，一次只读一个文件时吞吐被延迟卡住
    /// Files imported at once: macOS's exFAT (FSKit) has high per-request latency, so reading one file at a time is
    /// latency-bound.
    static let concurrency = 4

    public init(destination: URL) {
        self.destination = destination
    }

    /// 某个文件对应的目标目录：类型子文件夹下的年月日目录 / Destination folder for a file: a yyyyMMdd folder under its kind.
    ///
    /// # Examples
    /// ```
    /// let importer = PhotoImporter(destination: URL(fileURLWithPath: "/Photos"))
    /// // DSC00001.ARW, 2026-10-25 -> /Photos/Raw/20261025
    /// // C0001.MP4,    2026-10-25 -> /Photos/Video/20261025
    /// ```
    public func directory(for item: some ImportItem) -> URL {
        let date = item.captureDate
        let day = String(format: "%04d%02d%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0)
        // 扫描时已按扩展名过滤，这里总能认出类型；万一认不出就直接放日期目录 / scans filter by extension,
        // so the kind is always known; if not, fall back to the date folder alone
        let base = MediaKind(fileName: item.name).map { destination.appendingPathComponent($0.rawValue) } ?? destination
        return base.appendingPathComponent(day)
    }

    /// 执行导入，可以同时导入的来源最多 `concurrency` 个文件一起导；目标相同的文件依次导，不会同时写一个文件。
    /// 单个文件失败不会中断整批；取消任务会在文件之间停下；每处理完一个文件回调一次 `progress`。结果顺序与 files 相同
    /// Run the import, up to `concurrency` files at a time when the sources allow it; files with the same target go
    /// one after another so no file is written twice at once. A failing file does not stop the batch; cancelling
    /// stops between files; `progress` is called after each file. Results follow the order of files.
    ///
    /// - Throws: `ImportError.notEnoughSpace`、`CancellationError`，或目标目录无法创建/读取时的文件系统错误
    ///   / `ImportError.notEnoughSpace`, `CancellationError`, or a file-system error for the destination folder.
    ///
    /// # Examples
    /// ```
    /// let importer = PhotoImporter(destination: library)
    /// let report = try await importer.run(files: try MediaScanner.scan(card)) { print($0.completed, $0.total) }
    /// print(report.copied, report.skipped, report.failed)
    /// ```
    public func run(files: [any ImportItem],
                    progress: @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportReport {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try checkSpace(for: files)
        // 目标路径相同的文件分到同一组，组内依次导 / files with the same target share a group, imported in turn
        var groups: [String: [Int]] = [:], order: [String] = []
        for (index, file) in files.enumerated() {
            let key = directory(for: file).appendingPathComponent(file.name).path
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }
        let width = files.allSatisfy(\.importsConcurrently) ? Self.concurrency : 1
        var results = [ImportResult?](repeating: nil, count: files.count)
        var completed = 0
        try await withThrowingTaskGroup(of: [(Int, ImportResult)].self) { group in
            var pending = order.makeIterator()
            func addNext() {
                guard let key = pending.next(), let indices = groups[key] else { return }
                group.addTask {
                    var done: [(Int, ImportResult)] = []
                    for index in indices {
                        try Task.checkCancellation()
                        done.append((index, await importOne(files[index])))
                    }
                    return done
                }
            }
            for _ in 0..<width { addNext() }
            while let done = try await group.next() {
                for (index, result) in done {
                    results[index] = result
                    completed += 1
                    progress(ImportProgress(completed: completed, total: files.count, file: files[index].name))
                }
                addNext()
            }
        }
        return ImportReport(results: results.compactMap { $0 })
    }

    /// 删除已经安全进了照片库的源文件：只删复制成功或照片库里已有（跳过）、并且照片库里那份此刻确实还在的；
    /// 导入失败的绝不删。files 与 report.results 一一对应（`run` 的输入和输出）
    /// Delete sources that are safely in the library: only files that were copied or already present (skipped) and
    /// whose library copy still exists right now; failed files are never deleted. files and report.results line up
    /// (the input and output of `run`).
    ///
    /// # Examples
    /// ```
    /// let report = try await importer.run(files: files)
    /// let deletion = await PhotoImporter.deleteImportedSources(files, report: report)
    /// ```
    public static func deleteImportedSources(_ files: [any ImportItem], report: ImportReport) async -> DeletionReport {
        var deleted = 0
        var failures: [(name: String, reason: String)] = []
        for (file, result) in zip(files, report.results) {
            if case .failed = result.outcome { continue }
            guard let destination = result.destination, FileManager.default.fileExists(atPath: destination.path)
            else { continue }
            do {
                try await file.deleteSource()
                deleted += 1
            } catch {
                failures.append((file.name, "\(error)"))
            }
        }
        return DeletionReport(deleted: deleted, failures: failures)
    }

    /// 只统计目标位置还没有同名文件的部分，重复导入整张卡不会被误判为空间不足；读不到可用空间时不检查
    /// Counts only files with no same-name file at the destination, so re-importing a card is not rejected;
    /// skipped when the available capacity is unknown.
    func checkSpace(for files: [any ImportItem]) throws {
        let needed = files
            .filter { !FileManager.default.fileExists(atPath: directory(for: $0).appendingPathComponent($0.name).path) }
            .reduce(Int64(0)) { $0 + $1.size }
        let values = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64.max
        if needed > available { throw ImportError.notEnoughSpace(needed: needed, available: available) }
    }

    /// 导入一个文件；所有错误都转成 `.failed`，并清掉临时文件
    /// Import one file; every error becomes `.failed` and the temp file is removed.
    func importOne(_ item: some ImportItem) async -> ImportResult {
        let folder = directory(for: item)
        // 隐藏的临时文件：核对通过前不会出现正式文件名 / hidden temp file; the real name appears only after checking
        let part = folder.appendingPathComponent(".\(item.name).part")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(item.name)
            var staged = false
            // 同名同大小时，修改时间也一样就是导入过的同一张（导入时把来源的修改时间复制到了副本上），不读来源；
            // 修改时间不同才算哈希，来源拿不到哈希（PTP 相机）就先下载到 part 再算，之后复用这次下载
            // Same name and size: an equal modification time means the same photo imported before (the import copies
            // the source's time onto the copy), so the source is not read. Otherwise hash; when the source has no
            // hash (PTP) stage to `part` first and reuse that download.
            if FileManager.default.fileExists(atPath: target.path), try Self.size(of: target) == item.size {
                if let modified = item.preservedDates()[.modificationDate], try Self.sameTime(modified, target) {
                    return ImportResult(name: item.name, destination: target, outcome: .skippedDuplicate)
                }
                var hash = try await item.contentHash()
                if hash == nil {
                    try await stage(item, to: part)
                    staged = true
                    hash = try Self.sha256(of: part)
                }
                if try Self.sha256(of: target) == hash {
                    try? FileManager.default.removeItem(at: part)
                    return ImportResult(name: item.name, destination: target, outcome: .skippedDuplicate)
                }
            }
            if !staged { try await stage(item, to: part) }
            try FileManager.default.setAttributes(item.preservedDates(), ofItemAtPath: part.path)
            // 先落盘再改名：照片库里出现正式文件名时数据一定已在盘上 / flush before renaming, so a real name in the
            // library always means the data is on disk
            let handle = try FileHandle(forUpdating: part)
            defer { try? handle.close() }
            try handle.synchronize()
            // rename 会原子替换已有的同名文件 / rename atomically replaces an existing same-name file
            guard rename(part.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return ImportResult(name: item.name, destination: target, outcome: .copied)
        } catch {
            try? FileManager.default.removeItem(at: part)
            return ImportResult(name: item.name, destination: nil, outcome: .failed("\(error)"))
        }
    }

    /// 写入临时文件并核对大小必须和来源一致 / Write the temp file and check its size matches the source.
    func stage(_ item: some ImportItem, to part: URL) async throws {
        try? FileManager.default.removeItem(at: part)
        try await item.stage(to: part)
        let actual = try Self.size(of: part)
        guard actual == item.size else {
            throw ImportError.sizeMismatch(name: item.name, expected: item.size, actual: actual)
        }
    }

    /// 文件的修改时间与 date 相差不到 1 秒（exFAT 等文件系统的时间精度较低）/ Whether the file's modification time is
    /// within a second of date (exFAT and others store coarser times).
    static func sameTime(_ date: Date, _ url: URL) throws -> Bool {
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return modified.map { abs($0.timeIntervalSince(date)) < 1 } ?? false
    }

    static func size(of url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    /// 文件的 sha256（小写十六进制）/ sha256 of a file as lowercase hex.
    static func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: {
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `IMG_0001.CR3` + 1 -> `IMG_0001_1.CR3`
    static func numbered(_ name: String, _ number: Int) -> String {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        return url.pathExtension.isEmpty ? "\(stem)_\(number)" : "\(stem)_\(number).\(url.pathExtension)"
    }
}
