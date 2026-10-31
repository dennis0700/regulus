import Foundation
import Testing
@testable import RegulusCore

// MARK: - App 更新：Release 解析、版本比较、安装包校验（不联网）/ App update: release, versions, package checks (offline)

private func tempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regulus-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 只有 Info.plist 的假 App / A fake app with nothing but an Info.plist.
private func makeApp(at app: URL, id: String = "app.regulus.Regulus", version: String) throws {
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
}

/// 按 scripts/package.sh 的方式打包 / Zip the way scripts/package.sh does.
private func zipApp(_ app: URL, to zip: URL) throws {
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
    try ditto.run()
    ditto.waitUntilExit()
}

private func release(version: String = "0.2.0", sha256: String) -> AppRelease {
    AppRelease(version: version, notes: "", page: URL(string: "https://example.com")!,
               asset: URL(string: "https://example.com/Regulus.zip")!, size: 0, sha256: sha256)
}

private func releaseJSON(assets: String) -> Data {
    Data("""
    {"tag_name": "v0.2.0", "body": "- 修复", "html_url": "https://github.com/dennis0700/regulus/releases/tag/v0.2.0",
     "assets": [\(assets)]}
    """.utf8)
}

@Test func decodesTheLatestRelease() throws {
    let data = releaseJSON(assets: """
    {"name": "other.zip", "browser_download_url": "https://example.com/other.zip", "size": 1, "digest": "sha256:00"},
    {"name": "Regulus.zip", "browser_download_url": "https://example.com/Regulus.zip", "size": 42,
     "digest": "sha256:ABCDEF"}
    """)
    let release = try AppUpdate.decodeRelease(data)
    #expect(release.version == "0.2.0")
    #expect(release.notes == "- 修复")
    #expect(release.asset.absoluteString == "https://example.com/Regulus.zip")
    #expect(release.size == 42)
    #expect(release.sha256 == "abcdef")
}

@Test func rejectsAReleaseWithoutAVerifiablePackage() {
    let noPackage = releaseJSON(assets: """
    {"name": "other.zip", "browser_download_url": "https://example.com/other.zip", "size": 1, "digest": "sha256:00"}
    """)
    #expect(throws: RegulusError.self) { try AppUpdate.decodeRelease(noPackage) }
    let noDigest = releaseJSON(assets: """
    {"name": "Regulus.zip", "browser_download_url": "https://example.com/Regulus.zip", "size": 1, "digest": null}
    """)
    #expect(throws: RegulusError.self) { try AppUpdate.decodeRelease(noDigest) }
}

@Test func comparesVersionsNumerically() {
    #expect(AppUpdate.isNewer("0.2.0", than: "0.1.9"))
    #expect(AppUpdate.isNewer("0.10.0", than: "0.9.1"))
    #expect(AppUpdate.isNewer("1.0.1", than: "1.0"))
    #expect(!AppUpdate.isNewer("1.0", than: "1.0.0"))
    #expect(!AppUpdate.isNewer("0.1.0", than: "0.2.0"))
}

@Test func preparesAVerifiedPackage() throws {
    let dir = try tempDir("update")
    defer { try? FileManager.default.removeItem(at: dir) }
    let installed = dir.appendingPathComponent("Applications/Regulus.app")
    try makeApp(at: installed, version: "0.1.0")
    let build = dir.appendingPathComponent("build/Regulus.app")
    try makeApp(at: build, version: "0.2.0")
    let zip = dir.appendingPathComponent("Regulus.zip")
    try zipApp(build, to: zip)

    let newApp = try AppUpdate.prepare(zip, release: release(sha256: try PhotoImporter.sha256(of: zip)),
                                       replacing: installed)
    defer { try? FileManager.default.removeItem(at: newApp.deletingLastPathComponent()) }
    #expect(newApp.lastPathComponent == "Regulus.app")
    #expect(FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/Info.plist").path))
}

@Test func rejectsAPackageThatDoesNotMatchTheRelease() throws {
    let dir = try tempDir("update-bad")
    defer { try? FileManager.default.removeItem(at: dir) }
    let installed = dir.appendingPathComponent("Applications/Regulus.app")
    try makeApp(at: installed, version: "0.1.0")
    let build = dir.appendingPathComponent("build/Regulus.app")
    try makeApp(at: build, id: "com.example.Other", version: "0.2.0")
    let zip = dir.appendingPathComponent("Regulus.zip")
    try zipApp(build, to: zip)
    let digest = try PhotoImporter.sha256(of: zip)

    // 哈希不符 / hash mismatch
    #expect(throws: RegulusError.self) { try AppUpdate.prepare(zip, release: release(sha256: "00"), replacing: installed) }
    // 不是同一个 App / a different app
    #expect(throws: RegulusError.self) { try AppUpdate.prepare(zip, release: release(sha256: digest), replacing: installed) }
    // 版本号与 Release 不符 / version differs from the release
    try FileManager.default.removeItem(at: build.deletingLastPathComponent())
    try makeApp(at: build, version: "0.3.0")
    try FileManager.default.removeItem(at: zip)
    try zipApp(build, to: zip)
    let other = try PhotoImporter.sha256(of: zip)
    #expect(throws: RegulusError.self) { try AppUpdate.prepare(zip, release: release(sha256: other), replacing: installed) }
}
