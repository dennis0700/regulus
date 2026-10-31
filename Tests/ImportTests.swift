import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RegulusCore

/// 每个测试一个独立的临时目录，结束后删除 / One temporary directory per test, removed afterwards.
private func withTempDir(_ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regulus-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}

@discardableResult
private func write(_ text: String, to url: URL, modified: Date? = nil) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    return url
}

/// 用固定拍摄日期（默认 2026-10-24）包装一个文件，不读 EXIF / Wrap a file with a fixed capture date (2026-10-24 by default), no EXIF read.
private func sourceFile(_ url: URL, _ year: Int = 2026, _ month: Int = 10, _ day: Int = 24) throws -> SourceFile {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    return SourceFile(url: url, size: Int64(size), captureDate: DateComponents(year: year, month: month, day: day))
}

/// 生成 1x1 JPEG，exifDate 不为 nil 时写入 EXIF DateTimeOriginal / A 1x1 JPEG, with EXIF DateTimeOriginal when exifDate is set.
private func writeJPEG(to url: URL, exifDate: String?) throws {
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [:]
    if let exifDate { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate] }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

@Test func directoryUsesKindAndCompactDate() {
    let importer = PhotoImporter(destination: URL(fileURLWithPath: "/Photos"))
    let date = DateComponents(year: 2026, month: 3, day: 7)
    let expected = ["IMG_1.CR3": "/Photos/Raw/20260307", "IMG_2.jpg": "/Photos/Jpeg/20260307",
                    "IMG_3.HIF": "/Photos/HEIF/20260307", "C0001.MP4": "/Photos/Video/20260307"]
    for (name, path) in expected {
        let file = SourceFile(url: URL(fileURLWithPath: "/card/\(name)"), size: 1, captureDate: date)
        #expect(importer.directory(for: file).path == path, "\(name)")
    }
}

@Test func mediaKindFromExtension() {
    #expect(MediaKind(fileName: "DSC00001.ARW") == .raw)
    #expect(MediaKind(fileName: "DSCF0001.RAF") == .raw)
    #expect(MediaKind(fileName: "P1010025.ORI") == .raw)
    #expect(MediaKind(fileName: "A001C002.CRM") == .video)
    #expect(MediaKind(fileName: "DSC_0001.NEV") == .video)
    #expect(MediaKind(fileName: "a.jpeg") == .jpeg)
    #expect(MediaKind(fileName: "a.heic") == .heif)
    #expect(MediaKind(fileName: "clip.mov") == .video)
    #expect(MediaKind(fileName: "notes.txt") == nil)
}

@Test func parsesExifDateAndRejectsUnsetClock() {
    #expect(MediaScanner.parseExifDate("2026:10:24 07:30:01") == DateComponents(year: 2026, month: 10, day: 24))
    #expect(MediaScanner.parseExifDate("0000:00:00 00:00:00") == nil)
    #expect(MediaScanner.parseExifDate("2026:13:01 00:00:00") == nil)
    #expect(MediaScanner.parseExifDate("not a date") == nil)
}

@Test func scanKeepsPhotosAndSkipsHiddenAndOtherFiles() async throws {
    try await withTempDir { dir in
        try write("a", to: dir.appendingPathComponent("DCIM/100NIKON/DSC_0001.NEF"))
        try write("b", to: dir.appendingPathComponent("DCIM/100NIKON/DSC_0001.JPG"))
        try write("c", to: dir.appendingPathComponent("DCIM/100NIKON/._DSC_0001.NEF"))
        try write("d", to: dir.appendingPathComponent("DCIM/100NIKON/notes.txt"))
        try write("e", to: dir.appendingPathComponent("DCIM/101NIKON/DSC_0002.rw2"))
        // 视频（如索尼存在 PRIVATE/M4ROOT/CLIP）也要导入 / videos (e.g. Sony's PRIVATE/M4ROOT/CLIP) are imported too
        try write("f", to: dir.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"))
        // 索尼视频缩略图不是照片 / Sony video thumbnails are not photos
        try write("g", to: dir.appendingPathComponent("PRIVATE/M4ROOT/THMBNL/C0001T01.JPG"))
        let names = try MediaScanner.scan(dir).map(\.url.lastPathComponent)
        #expect(names == ["DSC_0001.JPG", "DSC_0001.NEF", "DSC_0002.rw2", "C0001.MP4"])
    }
}

/// CFexpress 卡根目录的 M4ROOT 下的视频也要导入，缩略图跳过 / Videos under M4ROOT at a CFexpress card's root are
/// imported too, thumbnails skipped.
@Test func scanFindsSonyVideosAtTheCardRoot() async throws {
    try await withTempDir { dir in
        try write("a", to: dir.appendingPathComponent("M4ROOT/CLIP/C0001.MP4"))
        try write("b", to: dir.appendingPathComponent("M4ROOT/THMBNL/C0001T01.JPG"))
        try write("c", to: dir.appendingPathComponent("M4ROOT/SUB/C0001S03.MP4"))
        try write("d", to: dir.appendingPathComponent("PRIVATE/M4ROOT/SUB/C0002S03.MP4"))
        #expect(try MediaScanner.scan(dir).map(\.url.lastPathComponent) == ["C0001.MP4"])
    }
}

/// 只录了视频、没有 DCIM 的卡也算存储卡；普通磁盘不算 / A card with only videos and no DCIM is still a card; a
/// plain disk is not.
@Test func cardsAreRecognisedByCameraFolders() async throws {
    try await withTempDir { dir in
        let photos = dir.appendingPathComponent("photos"), sd = dir.appendingPathComponent("sd")
        let cfexpress = dir.appendingPathComponent("cfa"), disk = dir.appendingPathComponent("disk")
        let canon = dir.appendingPathComponent("canon"), canonRaw = dir.appendingPathComponent("canon-raw")
        try write("a", to: photos.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW"))
        try write("b", to: sd.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"))
        try write("c", to: cfexpress.appendingPathComponent("M4ROOT/CLIP/C0002.MP4"))
        try write("d", to: disk.appendingPathComponent("Documents/notes.txt"))
        try write("e", to: canon.appendingPathComponent("XFVC/REEL_0001/A001C001.MP4"))
        try write("f", to: canonRaw.appendingPathComponent("CRM/REEL_0001/A001C002.CRM"))
        #expect(MediaScanner.isCameraCard(photos) && MediaScanner.isCameraCard(sd) && MediaScanner.isCameraCard(cfexpress))
        #expect(MediaScanner.isCameraCard(canon) && MediaScanner.isCameraCard(canonRaw))
        #expect(!MediaScanner.isCameraCard(disk))
    }
}

@Test func captureDateComesFromExifOtherwiseModificationTime() async throws {
    try await withTempDir { dir in
        try writeJPEG(to: dir.appendingPathComponent("with_exif.jpg"), exifDate: "2024:05:17 14:03:22")
        try writeJPEG(to: dir.appendingPathComponent("no_exif.jpg"), exifDate: nil)
        let modified = Calendar.current.date(from: DateComponents(year: 2020, month: 1, day: 2, hour: 12))!
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: dir.appendingPathComponent("no_exif.jpg").path)
        let dates = Dictionary(uniqueKeysWithValues: try MediaScanner.scan(dir).map { ($0.url.lastPathComponent, $0.captureDate) })
        #expect(dates["with_exif.jpg"] == DateComponents(year: 2024, month: 5, day: 17))
        #expect(dates["no_exif.jpg"] == DateComponents(year: 2020, month: 1, day: 2))
    }
}

@Test func copiesVerifiesAndLeavesSourceUntouched() async throws {
    try await withTempDir { dir in
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try write("raw bytes", to: dir.appendingPathComponent("card/IMG_0001.CR3"), modified: modified)
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        let report = try await importer.run(files: [try sourceFile(source)])
        let copy = dir.appendingPathComponent("out/Raw/20261024/IMG_0001.CR3")
        #expect(report.copied == 1 && report.failed == 0)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "raw bytes")
        #expect(try String(contentsOf: source, encoding: .utf8) == "raw bytes")
        let copyModified = try copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(copyModified == modified)
        // 不留 .part 临时文件 / no .part temp file left behind
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path)
        #expect(leftovers == ["IMG_0001.CR3"])
    }
}

@Test func reimportSkipsIdenticalFiles() async throws {
    try await withTempDir { dir in
        let source = try write("same", to: dir.appendingPathComponent("card/IMG_0001.CR3"))
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        let files = [try sourceFile(source)]
        _ = try await importer.run(files: files)
        let second = try await importer.run(files: files)
        #expect(second.copied == 0 && second.skipped == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("out/Raw/20261024").path)
        #expect(names == ["IMG_0001.CR3"])
    }
}

@Test func sameNameDifferentContentIsReplacedByTheCard() async throws {
    try await withTempDir { dir in
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        let first = try write("card one", to: dir.appendingPathComponent("card1/IMG_0001.CR3"))
        let second = try write("card two!", to: dir.appendingPathComponent("card2/IMG_0001.CR3"))
        _ = try await importer.run(files: [try sourceFile(first)])
        let report = try await importer.run(files: [try sourceFile(second)])
        let folder = dir.appendingPathComponent("out/Raw/20261024")
        #expect(report.copied == 1)
        #expect(try String(contentsOf: folder.appendingPathComponent("IMG_0001.CR3"), encoding: .utf8) == "card two!")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["IMG_0001.CR3"])
    }
}

@Test func failingFileDoesNotStopTheBatch() async throws {
    // 第一个源文件不存在 / the first source file does not exist
    try await withTempDir { dir in
        let good = try write("ok", to: dir.appendingPathComponent("card/IMG_0002.CR3"))
        let missing = SourceFile(url: dir.appendingPathComponent("card/IMG_0001.CR3"), size: 2,
                                 captureDate: DateComponents(year: 2026, month: 10, day: 24))
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        let report = try await importer.run(files: [missing, try sourceFile(good)])
        #expect(report.failed == 1 && report.copied == 1)
        let folder = dir.appendingPathComponent("out/Raw/20261024")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["IMG_0002.CR3"])
    }
}

@Test func rejectsImportThatCannotFit() async throws {
    try await withTempDir { dir in
        let huge = SourceFile(url: dir.appendingPathComponent("IMG.CR3"), size: Int64.max / 2,
                              captureDate: DateComponents(year: 2026, month: 10, day: 24))
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        await #expect(throws: ImportError.self) { try await importer.run(files: [huge]) }
    }
}

@Test func numberedInsertsSuffixBeforeExtension() {
    #expect(PhotoImporter.numbered("IMG_0001.CR3", 2) == "IMG_0001_2.CR3")
    #expect(PhotoImporter.numbered("README", 1) == "README_1")
}

// MARK: - 只靠目标目录判重，以来源为准 / Duplicates judged from the destination folder, the source wins

/// 照片库里那份写过评分（大小变了），重新导入用存储卡的版本覆盖它
/// Once a rating changed the library copy's size, re-importing replaces it with the card's version.
@Test func reimportReplacesARatedCopyWithTheCardVersion() async throws {
    try await withTempDir { dir in
        let source = try write("raw bytes", to: dir.appendingPathComponent("card/IMG_0001.CR3"))
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        let first = try await importer.run(files: [try sourceFile(source)])
        let copy = try #require(first.results[0].destination)
        try Data("raw bytes + xmp rating".utf8).write(to: copy)
        let second = try await importer.run(files: [try sourceFile(source)])
        #expect(second.copied == 1)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "raw bytes")
        let names = try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path)
        #expect(names == ["IMG_0001.CR3"])
    }
}

/// 新文件只下载一次、不算哈希；同名不同大小也不算哈希
/// A new file is downloaded once and never hashed; a same-name file of another size is not hashed either.
@Test func hashesOnlyWhenNameAndSizeMatch() async throws {
    try await withTempDir { dir in
        let importer = PhotoImporter(destination: dir)
        let downloads = Counter()
        let first = FakeCameraFile(name: "DSC_0001.NEF", content: "nef data", downloads: downloads)
        _ = try await importer.run(files: [first])
        let other = FakeCameraFile(name: "DSC_0001.NEF", content: "longer nef data", downloads: downloads)
        let report = try await importer.run(files: [other])
        #expect(report.copied == 1)
        #expect(downloads.value == 2 && first.hashRequests.value == 0 && other.hashRequests.value == 0)
    }
}

/// 照片库里那份被删了，重新复制 / Once the library copy is deleted, it is copied again.
@Test func deletedLibraryCopyIsCopiedAgain() async throws {
    try await withTempDir { dir in
        let source = try write("raw bytes", to: dir.appendingPathComponent("card/IMG_0001.CR3"))
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        let first = try await importer.run(files: [try sourceFile(source)])
        try FileManager.default.removeItem(at: try #require(first.results[0].destination))
        let second = try await importer.run(files: [try sourceFile(source)])
        #expect(second.copied == 1)
    }
}

// MARK: - 导入后删除源文件 / Deleting sources after import

@Test func deletesOnlySourcesThatAreSafelyInTheLibrary() async throws {
    try await withTempDir { dir in
        let copied = try write("new", to: dir.appendingPathComponent("card/IMG_0001.CR3"))
        let skipped = try write("old", to: dir.appendingPathComponent("card/IMG_0002.CR3"))
        let broken = try write("bad", to: dir.appendingPathComponent("card/IMG_0003.CR3"))
        let gone = try write("gone", to: dir.appendingPathComponent("card/IMG_0004.CR3"))
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        _ = try await importer.run(files: [try sourceFile(skipped)])

        // 声明的大小不对，暂存后的大小校验失败 / wrong declared size, so the staged copy fails the size check
        let wrongSize = SourceFile(url: broken, size: 99, captureDate: DateComponents(year: 2026, month: 10, day: 24))
        let files: [any ImportItem] = [try sourceFile(copied), try sourceFile(skipped), wrongSize, try sourceFile(gone)]
        let report = try await importer.run(files: files)
        #expect(report.copied == 2 && report.skipped == 1 && report.failed == 1)
        // 照片库里那份在删除前没了，源文件必须保留 / the library copy vanished before deletion, so keep the source
        try FileManager.default.removeItem(at: try #require(report.results[3].destination))

        let deletion = await PhotoImporter.deleteImportedSources(files, report: report)
        #expect(deletion.deleted == 2 && deletion.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copied.path))
        #expect(!FileManager.default.fileExists(atPath: skipped.path))
        #expect(FileManager.default.fileExists(atPath: broken.path))
        #expect(FileManager.default.fileExists(atPath: gone.path))
    }
}

// MARK: - 像 PTP 相机那样无法原地取哈希的来源 / Sources that cannot be hashed in place, like PTP cameras

/// 模拟相机文件：没有 contentHash，只能"下载"；可以故意下载出错误的大小
/// A fake camera file: no contentHash, download only; can deliberately deliver the wrong size.
private struct FakeCameraFile: ImportItem {
    let name: String
    let content: String
    var deliveredContent: String?
    var modified: Date?
    let downloads: Counter
    var hashRequests = Counter()
    var size: Int64 { Int64(content.utf8.count) }
    var captureDate: DateComponents { DateComponents(year: 2026, month: 10, day: 24) }

    func contentHash() async throws -> String? {
        hashRequests.increment()
        return nil
    }

    func stage(to part: URL) async throws {
        downloads.increment()
        try Data((deliveredContent ?? content).utf8).write(to: part)
    }

    func preservedDates() -> [FileAttributeKey: Date] { modified.map { [.modificationDate: $0] } ?? [:] }

    var importsConcurrently: Bool { false }

    func deleteSource() async throws {}
}

/// 线程安全的计数器；用引用类型，让 FakeCameraFile 的各份拷贝共享计数 / Thread-safe counter, a reference so copies share it.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Test func cameraReimportDownloadsToCompareThenSkipsWithoutLeftovers() async throws {
    try await withTempDir { dir in
        let importer = PhotoImporter(destination: dir)
        let downloads = Counter()
        let file = FakeCameraFile(name: "DSC_0001.NEF", content: "nef data", downloads: downloads)
        _ = try await importer.run(files: [file])
        let second = try await importer.run(files: [file])
        #expect(second.skipped == 1 && second.copied == 0)
        // 第二次只为比对下载一次 / the second run downloads once, just to compare
        #expect(downloads.value == 2)
        let folder = dir.appendingPathComponent("Raw/20261024")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["DSC_0001.NEF"])
    }
}

@Test func cameraSameNameSameSizeDifferentContentReplacesTheLibraryFile() async throws {
    // 未压缩 RAW 大小固定，同名同大小不代表同一张，要比哈希；内容不同时以相机为准
    // Uncompressed RAWs have a fixed size, so same name and size is not proof of the same photo; the hash decides,
    // and on a difference the camera wins.
    try await withTempDir { dir in
        let importer = PhotoImporter(destination: dir)
        let downloads = Counter()
        _ = try await importer.run(files: [FakeCameraFile(name: "DSC_0001.NEF", content: "photo A", downloads: downloads)])
        let report = try await importer.run(files: [FakeCameraFile(name: "DSC_0001.NEF", content: "photo B", downloads: downloads)])
        #expect(report.copied == 1 && report.skipped == 0)
        #expect(downloads.value == 2, "the second file is downloaded once, then reused for the copy")
        let folder = dir.appendingPathComponent("Raw/20261024")
        #expect(try String(contentsOf: folder.appendingPathComponent("DSC_0001.NEF"), encoding: .utf8) == "photo B")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["DSC_0001.NEF"])
    }
}

/// 下载内容比声明的短：报大小不符，目录里不留任何文件 / A short download fails with a size mismatch and leaves no file.
@Test func truncatedDownloadFailsAndLeavesNothingBehind() async throws {
    try await withTempDir { dir in
        let importer = PhotoImporter(destination: dir)
        let file = FakeCameraFile(name: "DSC_0002.NEF", content: "full data", deliveredContent: "full",
                                  downloads: Counter())
        let report = try await importer.run(files: [file])
        #expect(report.failed == 1)
        guard case let .failed(reason) = report.results[0].outcome else { Issue.record("expected failure"); return }
        #expect(reason.contains("size mismatch"))
        let folder = dir.appendingPathComponent("Raw/20261024")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}

// MARK: - 修改时间判重、并行导入 / Modification-time duplicates, parallel import

/// 同名同大小同修改时间：直接跳过，不下载也不算哈希 / Same name, size and modification time: skipped without
/// downloading or hashing.
@Test func sameModificationTimeSkipsWithoutReadingTheSource() async throws {
    try await withTempDir { dir in
        let importer = PhotoImporter(destination: dir)
        let downloads = Counter()
        let file = FakeCameraFile(name: "DSC_0001.NEF", content: "nef data",
                                  modified: Date(timeIntervalSince1970: 1_700_000_000), downloads: downloads)
        _ = try await importer.run(files: [file])
        let second = try await importer.run(files: [file])
        #expect(second.skipped == 1)
        #expect(downloads.value == 1 && file.hashRequests.value == 0)
    }
}

/// 并行导入：结果顺序与输入一致，全部复制成功 / Parallel import: results keep the input order and all are copied.
@Test func parallelImportKeepsTheInputOrder() async throws {
    try await withTempDir { dir in
        let sources = try (0..<20).map { try write("photo \($0)", to: dir.appendingPathComponent(String(format: "card/IMG_%04d.CR3", $0))) }
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        let report = try await importer.run(files: try sources.map { try sourceFile($0) })
        #expect(report.copied == 20)
        #expect(report.results.map(\.name) == sources.map(\.lastPathComponent))
    }
}

/// 两个来源对应同一个目标：依次导入，后一个为准，不留临时文件 / Two sources with the same target are imported in
/// turn, the later one wins, and no temp file is left.
@Test func sameTargetIsImportedInTurn() async throws {
    try await withTempDir { dir in
        let first = try write("from folder 100", to: dir.appendingPathComponent("card/100/IMG_0001.CR3"))
        let second = try write("from folder 101!", to: dir.appendingPathComponent("card/101/IMG_0001.CR3"))
        let importer = PhotoImporter(destination: dir.appendingPathComponent("out"))
        let report = try await importer.run(files: [try sourceFile(first), try sourceFile(second)])
        #expect(report.copied == 2)
        let folder = dir.appendingPathComponent("out/Raw/20261024")
        #expect(try String(contentsOf: folder.appendingPathComponent("IMG_0001.CR3"), encoding: .utf8) == "from folder 101!")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["IMG_0001.CR3"])
    }
}
