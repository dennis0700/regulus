import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RegulusCore

/// 本机下载过样片时才跑真实 RAW 的测试 / Real-RAW tests run only when the samples are present.
private let hasSamples = FileManager.default.fileExists(atPath: "samples/raw")

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regulus-rating-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 写一张小图；properties 为写入的 EXIF/TIFF 属性，metadata 为 XMP / Write a small image with EXIF/TIFF properties and XMP.
private func writeImage(_ url: URL, type: UTType = .jpeg, properties: [CFString: Any] = [:],
                        metadata: CGImageMetadata? = nil) throws {
    let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    if let metadata {
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
    } else {
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
}

/// EXIF IFD0 的 ImageDescription / EXIF IFD0 ImageDescription.
private func exifDescription(_ url: URL) -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    return (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFImageDescription] as? String
}

/// ImageIO 读到的属性，不含从 XMP 派生的 IPTC / Properties ImageIO reads, minus the IPTC it derives from XMP.
private func properties(_ url: URL) -> NSDictionary? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          var all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    all[kCGImagePropertyIPTCDictionary] = nil
    return all as NSDictionary
}

/// 把 JPEG 已有的 Exif 段换成只含 ImageDescription 的段，并去掉 APP13（IPTC）段
/// Replace the JPEG's existing Exif segment with one holding only ImageDescription, and drop APP13 (IPTC).
private func replaceExifDescription(_ text: String, in url: URL) throws {
    let value = Data(text.utf8) + [0]
    var tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01, 0x00, 0x0E, 0x01, 0x02, 0x00])
    tiff += withUnsafeBytes(of: UInt32(value.count).littleEndian) { Data($0) }
    tiff += Data([26, 0, 0, 0, 0, 0, 0, 0]) + value
    let exif = Data("Exif\0\0".utf8) + tiff
    let jpeg = try Data(contentsOf: url)
    var out = Data([0xFF, 0xD8]), offset = 2
    while jpeg[offset + 1] != 0xDA {
        let length = Int(jpeg[offset + 2]) << 8 | Int(jpeg[offset + 3])
        let segment = jpeg.subdata(in: offset..<(offset + 2 + length))
        if segment.subdata(in: 4..<min(10, segment.count)) == Data("Exif\0\0".utf8) {
            out += Data([0xFF, 0xE1, UInt8((exif.count + 2) >> 8), UInt8((exif.count + 2) & 0xFF)]) + exif
        } else if jpeg[offset + 1] != 0xED {
            out += segment
        }
        offset += 2 + length
    }
    try (out + jpeg.subdata(in: offset..<jpeg.count)).write(to: url)
}

private func sampleRaws() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "samples/raw"), includingPropertiesForKeys: nil)
        .filter { PhotoLibrary.rawExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func size(_ url: URL) throws -> Int {
    try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
}

@Test func jpegRatingRoundTripsClearsAndKeepsDates() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let photo = dir.appendingPathComponent("IMG_0001.JPG")
    try writeImage(photo)
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: photo.path)

    #expect(RatingFile.read(photo) == nil)
    try RatingFile.write(5, to: photo)
    #expect(RatingFile.read(photo) == 5)
    try RatingFile.write(0, to: photo)
    #expect(RatingFile.read(photo) == nil)

    let after = try photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    #expect(after == modified)
    // 不留临时文件，也不生成 .xmp 侧车 / no temp file and no .xmp sidecar left behind
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["IMG_0001.JPG"])
}

@Test func failedWriteLeavesTheOriginalUntouched() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notAPhoto = dir.appendingPathComponent("broken.ARW")
    try Data("not really a raw file".utf8).write(to: notAPhoto)
    #expect(throws: (any Error).self) {
        try RatingFile.write(3, to: notAPhoto)
    }
    #expect(try String(contentsOf: notAPhoto, encoding: .utf8) == "not really a raw file")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["broken.ARW"])
}

@Test func outOfRangeRatingIsRejectedBeforeTouchingTheFile() {
    #expect(throws: RegulusError.self) {
        try RatingFile.write(6, to: URL(fileURLWithPath: "/nonexistent.ARW"))
    }
}

/// 真实 RAW：评分读回一致，其他属性不变，重写不变大 / Real RAWs: rating reads back, nothing else changes, rewrites
/// do not grow the file.
@Test(.enabled(if: hasSamples))
func sampleRawsAcceptARatingInPlace() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let originals = try sampleRaws()
    #expect(originals.count == 10)
    for original in originals {
        let name = original.lastPathComponent
        let copy = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: original, to: copy)
        let before = try RatingFile.fingerprint(copy)
        let beforeProperties = properties(copy)
        try RatingFile.write(4, to: copy)
        #expect(RatingFile.read(copy) == 4, "\(name)")
        #expect(try RatingFile.fingerprint(copy) == before, "\(name)")
        #expect(properties(copy) == beforeProperties, "\(name)")
        let written = try size(copy)
        try RatingFile.write(2, to: copy)
        #expect(RatingFile.read(copy) == 2, "\(name)")
        #expect(try size(copy) == written, "\(name)")
    }
    let tags = RatingFile.readAll(originals.map { dir.appendingPathComponent($0.lastPathComponent) })
    #expect(tags.count == 10 && tags.values.allSatisfy { $0.rating == 2 })
}

// MARK: - 旗标 / Flags

/// 旗标写 xmp:Label = Select，排除写 xmp:Rating = -1 并清掉星级，评分又会覆盖排除
/// Picked writes xmp:Label = Select, rejected writes xmp:Rating = -1 clearing the stars, and a rating replaces a reject.
@Test(arguments: [UTType.jpeg, UTType.heic])
func flagsLiveInLabelAndRating(type: UTType) throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let photo = dir.appendingPathComponent("IMG_0001.\(type.preferredFilenameExtension ?? "img")")
    try writeImage(photo, type: type)
    #expect(RatingFile.tags(photo) == PhotoTags())

    try RatingFile.write(4, to: photo)
    try RatingFile.write(.picked, to: photo)
    #expect(RatingFile.tags(photo) == PhotoTags(rating: 4, flag: .picked))

    try RatingFile.write(.rejected, to: photo)
    #expect(RatingFile.tags(photo) == PhotoTags(rating: nil, flag: .rejected))

    try RatingFile.write(3, to: photo)
    #expect(RatingFile.tags(photo) == PhotoTags(rating: 3, flag: nil))

    try RatingFile.write(.picked, to: photo)
    try RatingFile.write(nil, to: photo)
    #expect(RatingFile.tags(photo) == PhotoTags(rating: 3, flag: nil))
    #expect(RatingFile.readAll([photo]) == [photo: PhotoTags(rating: 3)])
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [photo.lastPathComponent])
}

/// 真实 RAW：旗标和排除读回一致，图像特征不变 / Real RAWs: picked and rejected read back, image traits unchanged.
@Test(.enabled(if: hasSamples))
func sampleRawsAcceptFlagsInPlace() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    for original in try sampleRaws() {
        let name = original.lastPathComponent
        let copy = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: original, to: copy)
        let before = try RatingFile.fingerprint(copy)
        try RatingFile.write(.picked, to: copy)
        #expect(RatingFile.tags(copy).flag == .picked, "\(name)")
        try RatingFile.write(.rejected, to: copy)
        #expect(RatingFile.tags(copy).flag == .rejected, "\(name)")
        try RatingFile.write(nil, to: copy)
        #expect(RatingFile.tags(copy).flag == nil, "\(name)")
        #expect(try RatingFile.fingerprint(copy) == before, "\(name)")
    }
}

// MARK: - 鸟种信息 / Species info

private let owlet = SpeciesInfo(zh: "领鸺鹠", en: "Collared Owlet", sci: "Taenioptynx brodiei", inChina: true,
                                order: "鸮形目", family: "鸱鸮科", genus: "", iucn: "LC", rarity: 15.1)

@Test func speciesDescriptionHasNamesTaxonomyIUCNAndRarityButNoRating() {
    #expect(SpeciesTagFile.description(owlet) == """
        领鸺鹠 Collared Owlet（Taenioptynx brodiei）
        鸮形目 · 鸱鸮科
        IUCN 红色名录：LC 无危
        罕见度：能见（GBIF 15.1 / 100）
        """)
}

/// SuperPicky 式的旧说明和一个已有关键字 / An old SuperPicky-style caption and an existing keyword.
private func oldCaption() throws -> (properties: [CFString: Any], metadata: CGImageMetadata) {
    let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\
        <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Final rating: 3</rdf:li></rdf:Alt></dc:description>\
        <dc:subject><rdf:Bag><rdf:li>鸟</rdf:li></rdf:Bag></dc:subject>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
    let metadata = try #require(CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData))
    return ([kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "Final rating: 3"]], metadata)
}

@Test(arguments: [UTType.jpeg, UTType.heic])
func speciesTagsReplaceTheDescriptionAndAddTheKeywordOnce(type: UTType) throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let photo = dir.appendingPathComponent("IMG_0001.\(type.preferredFilenameExtension ?? "img")")
    let old = try oldCaption()
    if type == .jpeg {
        try writeImage(photo, metadata: old.metadata)
        try replaceExifDescription("Final rating: 3", in: photo)
    } else {
        try writeImage(photo, type: type, properties: old.properties, metadata: old.metadata)
    }
    // ImageIO 把 JPEG 的 EXIF 描述报成 IPTC，直接查字节 / ImageIO reports it as IPTC for JPEG; check the bytes
    let caption = Data("Final rating: 3".utf8)
    #expect(try Data(contentsOf: photo).range(of: caption) != nil)

    try SpeciesTagFile.write(owlet, to: photo)
    try SpeciesTagFile.write(owlet, to: photo)
    let tags = try #require(SpeciesTagFile.read(photo))
    #expect(tags.title == "领鸺鹠")
    #expect(tags.description == SpeciesTagFile.description(owlet))
    #expect(tags.keywords == ["鸟", "领鸺鹠"])
    #expect(try Data(contentsOf: photo).range(of: caption) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [photo.lastPathComponent])
}

/// 真实 RAW 写鸟种信息：关键字不重复，已有 EXIF 描述被替换 / Real RAWs: keyword added once, EXIF description
/// replaced.
@Test(.enabled(if: hasSamples))
func speciesTagsGoIntoEveryRaw() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    for original in try sampleRaws() {
        let name = original.lastPathComponent
        let photo = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: original, to: photo)
        let hadDescription = exifDescription(photo) != nil
        let before = try RatingFile.fingerprint(photo)
        try SpeciesTagFile.write(owlet, to: photo)
        try SpeciesTagFile.write(owlet, to: photo)
        let tags = try #require(SpeciesTagFile.read(photo), "\(name)")
        #expect(tags.title == "领鸺鹠", "\(name)")
        #expect(tags.description == SpeciesTagFile.description(owlet), "\(name)")
        #expect(tags.keywords == ["领鸺鹠"], "\(name)")
        #expect(try RatingFile.fingerprint(photo) == before, "\(name)")
        if hadDescription { #expect(exifDescription(photo) == SpeciesTagFile.description(owlet), "\(name)") }
    }
}

/// 真实 JPEG（含重复评分、Exif 内嵌 XMP、接近 64KB 的 XMP），像素不变 / Real JPEGs (repeated rating, XMP inside
/// Exif, XMP near 64 KB); pixels unchanged.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "samples/jpeg")))
func sampleJpegsAcceptRatingAndSpecies() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let originals = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "samples/jpeg"),
                                                                includingPropertiesForKeys: nil)
    #expect(originals.count == 15)
    for original in originals {
        let name = original.lastPathComponent
        let photo = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: original, to: photo)
        try RatingFile.write(3, to: photo)
        try SpeciesTagFile.write(owlet, to: photo)
        #expect(RatingFile.read(photo) == 3, "\(name)")
        #expect(SpeciesTagFile.read(photo)?.title == "领鸺鹠", "\(name)")
        let pixels = { (url: URL) in
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?
                .dataProvider?.data as Data?
        }
        #expect(pixels(photo) == pixels(original), "\(name)")
    }
}

@Test func onlyTIFFStylePhotosCanHoldTags() {
    #expect(RatingFile.canWrite(URL(fileURLWithPath: "/Photos/DSC00001.ARW")))
    #expect(RatingFile.canWrite(URL(fileURLWithPath: "/Photos/P1010025.ORI")))
    #expect(!RatingFile.canWrite(URL(fileURLWithPath: "/Photos/DSCF0001.RAF")))
    #expect(!RatingFile.canWrite(URL(fileURLWithPath: "/Photos/C0001.MP4")))
}
