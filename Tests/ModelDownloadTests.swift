import Foundation
import Testing
@testable import RegulusCore

// MARK: - 模型下载：清单解析与安装（不联网）/ Model download: manifest and install (offline)

private func tempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regulus-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 按发布包的结构造一个 birdtrace 压缩包 / Build a birdtrace zip laid out like the release.
private func makeZip(in dir: URL) throws -> URL {
    let content = dir.appendingPathComponent("content")
    let pkg = content.appendingPathComponent("birdtrace_fp16.mlpackage")
    try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: pkg.appendingPathComponent("Manifest.json"))
    for name in ["birdtrace_class_map.json", "species_names.json", "LICENSE", "NOTICE.txt"] {
        try Data(name.utf8).write(to: content.appendingPathComponent(name))
    }
    let zip = dir.appendingPathComponent("birdtrace-fp16.zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", content.path, zip.path]
    try ditto.run()
    ditto.waitUntilExit()
    return zip
}

private func asset(sha256: String) -> ModelAsset {
    ModelAsset(name: "birdtrace", file: "birdtrace-fp16.zip", package: "birdtrace_fp16.mlpackage", size: 1,
               sha256: sha256, license: "CC-BY-NC-4.0", upstream: "https://example.com",
               url: URL(fileURLWithPath: "/dev/null"))
}

@Test func manifestDecodesTheReleaseFormat() throws {
    let json = """
    {"models": [{"name": "flight", "file": "flight-fp16.zip", "package": "flight_fp16.mlpackage", "size": 20013227,
      "sha256": "1d13", "license": "GPL-3.0-only", "upstream": "https://github.com/jamesphotography/SuperPicky",
      "url": "https://github.com/dennis0700/superpicky-coreml/releases/download/v1.0.0/flight-fp16.zip"}]}
    """
    let assets = try ModelDownload.decodeManifest(Data(json.utf8))
    #expect(assets.map(\.package) == ["flight_fp16.mlpackage"])
    #expect(assets[0].size == 20_013_227)
}

@Test func manifestAppendsDataPackagesAndInstallsThemAtTheRoot() throws {
    let json = """
    {"models": [], "data": [{"name": "regions", "file": "regions.zip", "package": "regions.json", "size": 216063,
      "sha256": "c4c4", "license": "AGPL-3.0-only AND LicenseRef-eBird-API-Terms-of-Use",
      "upstream": "https://github.com/jamesphotography/SuperPicky",
      "url": "https://github.com/dennis0700/superpicky-coreml/releases/download/v1.1.0/regions.zip"}]}
    """
    let assets = try ModelDownload.decodeManifest(Data(json.utf8))
    #expect(assets.map(\.installPath) == ["regions.json"])
    #expect(asset(sha256: "").installPath == "coreml/birdtrace_fp16.mlpackage")
}

@Test func manifestPackagesCoverThePipeline() {
    // Pipeline 加载的 5 个模型按发布包的 `<名字>_fp16.mlpackage` 命名 / Pipeline's five models follow the release naming
    let packages = Set(Pipeline.packageNames.values.map { "\($0)_fp16.mlpackage" })
    #expect(packages.count == 5 && packages.contains("yolo11l-seg_fp16.mlpackage"))
}

@Test func installPlacesFilesWhereTheAnalyzerLooks() throws {
    let dir = try tempDir("models")
    defer { try? FileManager.default.removeItem(at: dir) }
    let zip = try makeZip(in: dir)
    let models = dir.appendingPathComponent("models")
    // 旧的编译缓存要被清掉 / a stale compiled cache must go
    let compiled = models.appendingPathComponent("compiled/birdtrace_fp16.mlmodelc")
    try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
    // 清单里大写的 sha256 也要认 / an upper-case sha256 in the manifest must still match
    let item = asset(sha256: try PhotoImporter.sha256(of: zip).uppercased())

    try ModelDownload.install(zip, asset: item, into: models)
    // 再装一次覆盖同名文件 / installing again replaces the files
    try ModelDownload.install(zip, asset: item, into: models)

    let fm = FileManager.default
    #expect(ModelDownload.isInstalled(item, in: models))
    #expect(fm.fileExists(atPath: models.appendingPathComponent("coreml/birdtrace_fp16.mlpackage/Manifest.json").path))
    #expect(fm.fileExists(atPath: models.appendingPathComponent("birdtrace_class_map.json").path))
    #expect(fm.fileExists(atPath: models.appendingPathComponent("birdtrace/species_names.json").path))
    #expect(fm.fileExists(atPath: models.appendingPathComponent("licenses/birdtrace/LICENSE").path))
    #expect(fm.fileExists(atPath: models.appendingPathComponent("licenses/birdtrace/NOTICE.txt").path))
    #expect(!fm.fileExists(atPath: compiled.path))
    #expect(PhotoAnalyzer(repo: dir).missingFiles.allSatisfy { !$0.contains("birdtrace") })
    // 装的是清单里这一版；清单换了新包就不再是最新 / this is the manifest's version; a new zip makes it outdated
    #expect(ModelDownload.isCurrent(item, in: models))
    #expect(!ModelDownload.isCurrent(asset(sha256: String(repeating: "1", count: 64)), in: models))
}

@Test func installRejectsAChecksumMismatch() throws {
    let dir = try tempDir("models-bad")
    defer { try? FileManager.default.removeItem(at: dir) }
    let zip = try makeZip(in: dir)
    let models = dir.appendingPathComponent("models")
    #expect(throws: RegulusError.self) {
        try ModelDownload.install(zip, asset: asset(sha256: String(repeating: "0", count: 64)), into: models)
    }
    #expect(!FileManager.default.fileExists(atPath: models.appendingPathComponent("coreml").path))
}

@Test func installPutsADataPackageAtTheRoot() throws {
    let dir = try tempDir("models-data")
    defer { try? FileManager.default.removeItem(at: dir) }
    let content = dir.appendingPathComponent("content")
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    for name in ["regions.json", "NOTICE.txt"] {
        try Data(name.utf8).write(to: content.appendingPathComponent(name))
    }
    let zip = dir.appendingPathComponent("regions.zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", content.path, zip.path]
    try ditto.run()
    ditto.waitUntilExit()
    let item = ModelAsset(name: "regions", file: "regions.zip", package: "regions.json", size: 1,
                          sha256: try PhotoImporter.sha256(of: zip), license: "", upstream: "",
                          url: URL(fileURLWithPath: "/dev/null"))
    let models = dir.appendingPathComponent("models")

    try ModelDownload.install(zip, asset: item, into: models)

    #expect(FileManager.default.fileExists(atPath: models.appendingPathComponent("regions.json").path))
    #expect(FileManager.default.fileExists(atPath: models.appendingPathComponent("licenses/regions/NOTICE.txt").path))
    #expect(ModelDownload.isCurrent(item, in: models))
}

@Test func sameContentInANewZipCountsAsCurrent() throws {
    let json = """
    {"models": [{"name": "birdtrace", "file": "birdtrace-fp16.zip", "package": "birdtrace_fp16.mlpackage",
      "size": 1, "sha256": "AA", "content_sha256": "C0FFEE", "license": "", "upstream": "",
      "url": "https://example.com/birdtrace-fp16.zip"}]}
    """
    #expect(try ModelDownload.decodeManifest(Data(json.utf8)).map(\.version) == ["c0ffee"])
    let dir = try tempDir("models-content")
    defer { try? FileManager.default.removeItem(at: dir) }
    let zip = try makeZip(in: dir)
    let models = dir.appendingPathComponent("models")
    var installed = asset(sha256: try PhotoImporter.sha256(of: zip))
    installed.contentSha256 = "c0ffee"

    try ModelDownload.install(zip, asset: installed, into: models)

    // 新发布只换了 SOURCE.txt：zip 的 sha256 变了，内容哈希没变 / a release that only changed SOURCE.txt
    var rebuilt = asset(sha256: String(repeating: "1", count: 64))
    rebuilt.contentSha256 = "C0FFEE"
    #expect(ModelDownload.isCurrent(rebuilt, in: models))
    rebuilt.contentSha256 = "beef"
    #expect(!ModelDownload.isCurrent(rebuilt, in: models))
}
