import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RegulusCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regulus-library-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
}

/// 写一张 width×height 的 JPEG，可带 EXIF 方向 / Write a width×height JPEG, optionally with an EXIF orientation.
private func writeJPEG(_ url: URL, width: Int, height: Int, orientation: Int? = nil) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [:]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

@Test func scanBuildsTreeWithRecursiveCountsAndSkipsHidden() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try touch(root.appendingPathComponent("2026/2026-10-23/DSC_0001.NEF"))
    try touch(root.appendingPathComponent("2026/2026-10-24/DSC_0002.NEF"))
    try touch(root.appendingPathComponent("2026/2026-10-24/DSC_0002.JPG"))
    try touch(root.appendingPathComponent("2026/2026-10-24/.DSC_0003.NEF.part"))
    try touch(root.appendingPathComponent("2026/2026-10-24/notes.txt"))
    try touch(root.appendingPathComponent(".hidden/DSC_9999.NEF"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)

    let snapshot = try PhotoLibrary.scan(root)
    #expect(snapshot.photos.map(\.url.lastPathComponent) == ["DSC_0001.NEF", "DSC_0002.JPG", "DSC_0002.NEF"])
    #expect(snapshot.folders.map(\.url) == [root.standardizedFileURL])
    let library = snapshot.folders[0]
    #expect(library.count == 3)
    #expect(library.children.map(\.name) == ["2026", "Empty"])
    let year = library.children[0]
    #expect(year.count == 3)
    #expect(year.children.map(\.name) == ["2026-10-23", "2026-10-24"])
    #expect(year.children.map(\.count) == [1, 2])
    #expect(year.children[0].children.isEmpty)
    #expect(library.children[1].count == 0)
    #expect(snapshot.photos(in: year.children[1].url).map(\.name) == ["DSC_0002", "DSC_0002"])
    #expect(snapshot.photos(in: year.url).count == 3)
}

@Test func addedFoldersAreScannedAsTopLevelFolders() throws {
    let root = try makeTempDir()
    let outside = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    try touch(root.appendingPathComponent("2026/a.NEF"))
    try touch(outside.appendingPathComponent("Trip/b.NEF"))
    try touch(outside.appendingPathComponent("c.JPG"))
    let missing = URL(fileURLWithPath: "/nonexistent/regulus-\(UUID().uuidString)")

    let snapshot = try PhotoLibrary.scan(root, addedFolders: [outside, missing])
    #expect(snapshot.photos.count == 3)
    #expect(snapshot.folders.map(\.url) == [root, outside, missing].map(\.standardizedFileURL))
    #expect(snapshot.folders[0].children.map(\.name) == ["2026"])
    #expect(snapshot.folders[1].count == 2)
    #expect(snapshot.folders[1].children.map(\.name) == ["Trip"])
    #expect(snapshot.folders[2].count == 0)
    #expect(snapshot.photos(in: outside).count == 2)
}

@Test func excludedFoldersAreSkipped() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try touch(root.appendingPathComponent("keep/a.NEF"))
    try touch(root.appendingPathComponent("drop/sub/b.NEF"))
    let snapshot = try PhotoLibrary.scan(root, excludedFolders: [root.appendingPathComponent("drop")])
    #expect(snapshot.folders[0].children.map(\.name) == ["keep"])
    #expect(snapshot.photos.map(\.name) == ["a"])
}

@Test func photosInFolderDoesNotMatchSiblingWithSamePrefix() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try touch(root.appendingPathComponent("2026-10-2/a.NEF"))
    try touch(root.appendingPathComponent("2026-10-24/b.NEF"))
    let snapshot = try PhotoLibrary.scan(root)
    #expect(snapshot.photos(in: root.appendingPathComponent("2026-10-2")).map(\.name) == ["a"])
}

@Test func rawFlagFollowsExtension() {
    #expect(LibraryPhoto(url: URL(fileURLWithPath: "/a/DSC.ARW")).isRaw)
    #expect(!LibraryPhoto(url: URL(fileURLWithPath: "/a/DSC.JPG")).isRaw)
}

@Test func marqueeModesCombineLikeFinder() {
    let base: Set = [1, 2]
    let hits: Set = [2, 3]
    #expect(MarqueeMode.replace.apply(base: base, hits: hits) == [2, 3])
    #expect(MarqueeMode.add.apply(base: base, hits: hits) == [1, 2, 3])
    #expect(MarqueeMode.toggle.apply(base: base, hits: hits) == [1, 3])
    // 框缩小到不碰任何格子时，回到拖动开始时的选择（替换模式则为空）
    // Shrinking the box off every cell returns to the starting selection (empty when replacing).
    #expect(MarqueeMode.add.apply(base: base, hits: []) == base)
    #expect(MarqueeMode.toggle.apply(base: base, hits: []) == base)
    #expect(MarqueeMode.replace.apply(base: base, hits: Set<Int>()).isEmpty)
}

@Test func thumbnailIsBoundedAndPortraitSizeIsSwapped() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let landscape = root.appendingPathComponent("landscape.jpg")
    let portrait = root.appendingPathComponent("portrait.jpg")
    try writeJPEG(landscape, width: 1200, height: 800)
    try writeJPEG(portrait, width: 1200, height: 800, orientation: 6)

    let wide = try #require(ThumbnailCache.make(landscape, maxPixelSize: 300))
    #expect((wide.pixelWidth, wide.pixelHeight) == (1200, 800))
    #expect(max(wide.image.width, wide.image.height) <= 300)

    let tall = try #require(ThumbnailCache.make(portrait, maxPixelSize: 300))
    #expect((tall.pixelWidth, tall.pixelHeight) == (800, 1200))
    #expect(tall.image.height > tall.image.width)
}

@Test func thumbnailOfMissingFileIsNil() {
    #expect(ThumbnailCache.make(URL(fileURLWithPath: "/nonexistent/x.NEF"), maxPixelSize: 256) == nil)
}

/// 本机下载过样片时，10 张样片 RAW 都能出不超过 512 的缩略图，并报出原图尺寸
/// With the samples present, all 10 sample RAWs yield a thumbnail within 512 px and report the full image size.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "samples/raw")))
func thumbnailsForSampleRaws() throws {
    let snapshot = try PhotoLibrary.scan(URL(fileURLWithPath: "samples/raw"))
    #expect(snapshot.photos.count == 10)
    for photo in snapshot.photos {
        let thumb = try #require(ThumbnailCache.make(photo.url, maxPixelSize: 512), "\(photo.url.lastPathComponent)")
        #expect(max(thumb.image.width, thumb.image.height) <= 512)
        #expect(thumb.pixelWidth >= 3000, "\(photo.url.lastPathComponent): \(thumb.pixelWidth)x\(thumb.pixelHeight)")
    }
}

// MARK: - 内嵌 JPEG / Embedded JPEGs

private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }

/// 一个 TIFF 目录，每项都是 count 为 1 的 LONG / One TIFF directory whose entries are all single LONGs.
private func directory(_ entries: [(tag: UInt16, value: UInt32)], next: UInt32) -> [UInt8] {
    le16(UInt16(entries.count)) + entries.flatMap { le16($0.tag) + le16(4) + le32(1) + le32($0.value) } + le32(next)
}

@Test func embeddedPreviewPicksTheLargestAcrossTheChainAndSubIFDs() {
    // 布局：头 0–8，IFD0 8–50，IFD1 50–80，SubIFD 80–110，小 JPEG 110–120，大 JPEG 120–220，假 JPEG 220–720
    // Layout: header 0–8, IFD0 8–50, IFD1 50–80, SubIFD 80–110, small JPEG 110–120, big JPEG 120–220, fake 220–720
    var bytes: [UInt8] = [0x49, 0x49] + le16(42) + le32(8)
    bytes += directory([(0x0201, 110), (0x0202, 10), (0x014A, 80)], next: 50)
    bytes += directory([(0x0201, 120), (0x0202, 100)], next: 0)
    // SubIFD 里最大的一段不是 JPEG（没有 FF D8），必须跳过 / the largest blob, in the SubIFD, is not a JPEG and must be skipped
    bytes += directory([(0x0201, 220), (0x0202, 500)], next: 0)
    bytes += [0xFF, 0xD8] + Array(repeating: 1, count: 8)
    bytes += [0xFF, 0xD8] + Array(repeating: 2, count: 98)
    bytes += Array(repeating: 0, count: 500)
    #expect(bytes.count == 720)

    let jpeg = EmbeddedPreview.largest(inTIFF: Data(bytes))
    #expect(jpeg?.count == 100)
    #expect(jpeg?.last == 2)
    #expect(EmbeddedPreview.largest(inTIFF: Data("not a tiff".utf8)) == nil)
}

/// 索尼 ARW 的全尺寸 JpgFromRaw 在 IFD2，尼康 NEF 的在 SubIFD；ImageIO 对索尼只给 1616 宽的小图
/// Sony ARW keeps its full-size JpgFromRaw in IFD2, Nikon NEF in a SubIFD; ImageIO gives Sony only a 1616-wide preview.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "samples/raw")),
      arguments: ["sony_a1_lossless.ARW", "nikon_z9_he.NEF"])
func fullSizePreviewUsesTheLargeEmbeddedJPEG(name: String) throws {
    let url = URL(fileURLWithPath: "samples/raw/\(name)")
    let full = try #require(ThumbnailCache.makeFullSize(url))
    #expect(full.image.width == full.pixelWidth && full.image.height == full.pixelHeight,
            "\(name): \(full.image.width)x\(full.image.height) vs \(full.pixelWidth)x\(full.pixelHeight)")
    let small = try #require(ThumbnailCache.make(url, maxPixelSize: 4096))
    #expect(full.image.width >= small.image.width)
}

/// 松下、奥林巴斯的内嵌预览只有 1920 / 3200 宽，要解码 RAW 才能接近原图尺寸
/// Panasonic and Olympus embed only 1920 / 3200 wide previews, so the RAW must be decoded to get near full size.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "samples/raw")),
      arguments: ["panasonic_s5m2_P1126460.RW2", "olympus_em1m3_3160531.ORF"])
func fullSizePreviewDecodesRawWhenThePreviewIsSmall(name: String) throws {
    let full = try #require(ThumbnailCache.makeFullSize(URL(fileURLWithPath: "samples/raw/\(name)")))
    #expect(!ThumbnailCache.isTooSmall(full), "\(name): \(full.image.width)x\(full.image.height) vs \(full.pixelWidth)x\(full.pixelHeight)")
}

// MARK: - 文件夹监听 / Folder watching

/// 只看监听目录以下的路径是否隐藏，上级隐藏不影响；监听目录自身的事件忽略
/// Only components below the watched folder count as hidden, not its parents; events on the folder itself are ignored.
@Test func watcherIgnoresHiddenItemsBelowTheWatchedFolder() {
    let roots = ["/Volumes/Disk/.hidden-parent/Photos"]
    #expect(FolderWatcher.isRelevant("/Volumes/Disk/.hidden-parent/Photos/Selected", roots: roots))
    #expect(FolderWatcher.isRelevant("/Volumes/Disk/.hidden-parent/Photos/Raw/20261025/DSC00001.ARW", roots: roots))
    #expect(!FolderWatcher.isRelevant("/Volumes/Disk/.hidden-parent/Photos/.regulus/flags.json", roots: roots))
    #expect(!FolderWatcher.isRelevant("/Volumes/Disk/.hidden-parent/Photos/Raw/.DSC00001.rating-tmp.ARW", roots: roots))
    #expect(!FolderWatcher.isRelevant("/Volumes/Disk/.hidden-parent/Photos", roots: roots))
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// 在 App 外新建文件夹会收到通知；只写隐藏文件（如 .regulus/）不会 / Creating a folder outside the app is reported;
/// writing only hidden files (such as .regulus/) is not.
@Test func watcherReportsANewFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("regulus-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let changes = ChangeCounter()
    let watcher = FolderWatcher([root], latency: 0.2) { changes.increment() }
    try await Task.sleep(for: .milliseconds(300))
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".regulus"), withIntermediateDirectories: false)
    try Data("{}".utf8).write(to: root.appendingPathComponent(".regulus/flags.json"))
    try await Task.sleep(for: .seconds(1))
    #expect(changes.value == 0)

    try FileManager.default.createDirectory(at: root.appendingPathComponent("Selected"), withIntermediateDirectories: false)
    for _ in 0..<50 where changes.value == 0 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(changes.value > 0)
    withExtendedLifetime(watcher) {}
}

// MARK: - 移动照片 / Moving photos

@Test func moverRenamesOnCollisionSkipsSameFolderAndReportsFailures() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("regulus-move-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("Raw"), selected = root.appendingPathComponent("Selected")
    for folder in [raw, selected] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let a = raw.appendingPathComponent("DSC00001.ARW"), b = raw.appendingPathComponent("DSC00002.ARW")
    try Data("a".utf8).write(to: a)
    try Data("b".utf8).write(to: b)
    // 目标里已有同名文件，不能被覆盖 / a same-name file already in the target must not be overwritten
    try Data("old".utf8).write(to: selected.appendingPathComponent("DSC00001.ARW"))
    let already = selected.appendingPathComponent("DSC00009.ARW")
    try Data("c".utf8).write(to: already)
    let missing = raw.appendingPathComponent("DSC00003.ARW")

    let results = PhotoMover.move([a, b, already, missing], to: selected)
    #expect(results[0].destination?.lastPathComponent == "DSC00001_1.ARW")
    #expect(results[1].destination?.lastPathComponent == "DSC00002.ARW")
    #expect(results[2].destination == nil && results[2].error == nil)
    #expect(results[3].destination == nil && results[3].error != nil)
    #expect(try String(contentsOf: selected.appendingPathComponent("DSC00001.ARW"), encoding: .utf8) == "old")
    #expect(try String(contentsOf: selected.appendingPathComponent("DSC00001_1.ARW"), encoding: .utf8) == "a")
    #expect(!FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path))
}

// MARK: - 固定位置 / Fixed positions

@Test func fixedItemsStayPutWhileOthersMove() {
    let items = ["A", "B", "C", "D", "E"]
    let fixedB: (String) -> Bool = { $0 == "B" }
    // 没有固定项时与 Array.move 一致 / without fixed items it matches Array.move
    #expect(FixedPositions.move(items, from: [4], to: 0) { _ in false } == ["E", "A", "B", "C", "D"])
    // 往前拖越过固定项，B 仍在下标 1 / dragging toward the start past the fixed item keeps B at index 1
    #expect(FixedPositions.move(items, from: [4], to: 0, isFixed: fixedB) == ["E", "B", "A", "C", "D"])
    // 往后拖到末尾 / dragging to the end
    #expect(FixedPositions.move(items, from: [0], to: 5, isFixed: fixedB) == ["C", "B", "D", "E", "A"])
    // 拖固定项本身不动 / dragging the fixed item itself does nothing
    #expect(FixedPositions.move(items, from: [1], to: 4, isFixed: fixedB) == items)
    // 两个固定项（首、尾）/ two fixed items, first and last
    #expect(FixedPositions.move(items, from: [3], to: 1) { $0 == "A" || $0 == "E" } == ["A", "D", "B", "C", "E"])
}

// MARK: - 视频 / Videos

/// 写一段 64×48、竖拍（转 90°）的 H.264 小视频 / Write a tiny 64×48 H.264 clip recorded in portrait (turned 90°).
private func writePortraitVideo(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
    ])
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<3 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0x80, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

/// 视频列进照片库，缩略图取第一帧并按旋转转正 / Videos are listed in the library, and their thumbnail is the first
/// frame turned upright.
@Test func videosAreListedAndGetUprightThumbnails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("regulus-video-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let clip = root.appendingPathComponent("Video/20261029/C0001.MP4")
    try FileManager.default.createDirectory(at: clip.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await writePortraitVideo(to: clip)

    let snapshot = try PhotoLibrary.scan(root)
    #expect(snapshot.photos.map(\.url.lastPathComponent) == ["C0001.MP4"])
    #expect(snapshot.photos.first?.isVideo == true)
    #expect(snapshot.folders.first?.count == 1)

    let thumb = try #require(await ThumbnailCache().thumbnail(for: clip, maxPixelSize: 512))
    #expect(thumb.pixelWidth == 48 && thumb.pixelHeight == 64)
    #expect(thumb.image.height > thumb.image.width)
}
