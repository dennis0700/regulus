import Foundation
import os

/// 从 superpicky-coreml 的 GitHub Release 下载并安装模型
/// Download and install the models from the superpicky-coreml GitHub release.
///
/// 始终取最新的 Release，安装后的目录结构即 `PhotoAnalyzer` 需要的 `models/`
/// Always uses the latest release; the installed layout is the `models/` `PhotoAnalyzer` expects.
public enum ModelDownload {
    public static let releasePage = URL(string: "https://github.com/dennis0700/superpicky-coreml/releases/latest")!
    public static let manifestURL =
        URL(string: "https://github.com/dennis0700/superpicky-coreml/releases/latest/download/manifest.json")!

    private struct Manifest: Codable {
        let models: [ModelAsset]
        /// 不含模型的数据包，较早的清单没有 / Data packages without a model; absent from older manifests.
        let data: [ModelAsset]?
    }

    /// 解析 manifest.json，模型在前、数据包在后 / Decode manifest.json, models first, then data packages.
    ///
    /// # Examples
    /// ```
    /// let assets = try ModelDownload.decodeManifest(data)
    /// ```
    public static func decodeManifest(_ data: Data) throws -> [ModelAsset] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        return manifest.models + (manifest.data ?? [])
    }

    /// 下载并解析 manifest.json，HTTP 状态不是 200 时抛错 / Fetch and decode manifest.json; throws unless HTTP 200.
    ///
    /// # Examples
    /// ```
    /// let assets = try await ModelDownload.fetchManifest()
    /// ```
    public static func fetchManifest(from url: URL = manifestURL) async throws -> [ModelAsset] {
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkStatus(response, url)
        return try decodeManifest(data)
    }

    /// 主文件是否已装在 `installPath`（不检查版本）
    /// Whether the main item exists at `installPath` (version not checked).
    ///
    /// # Examples
    /// ```
    /// ModelDownload.isInstalled(asset, in: modelsDir)
    /// ```
    public static func isInstalled(_ asset: ModelAsset, in models: URL) -> Bool {
        FileManager.default.fileExists(atPath: models.appendingPathComponent(asset.installPath).path)
    }

    /// 已安装且与清单中的版本一致（按安装时写入 `licenses/<name>/.sha256` 的 `version` 判断，模型内容没变时
    /// 即使压缩包换了也算最新）
    /// Installed and matching the manifest's version (by the `version` written to `licenses/<name>/.sha256` at
    /// install time, so an unchanged model counts as current even in a new zip).
    ///
    /// # Examples
    /// ```
    /// ModelDownload.isCurrent(asset, in: modelsDir)
    /// ```
    public static func isCurrent(_ asset: ModelAsset, in models: URL) -> Bool {
        let recorded = try? String(contentsOf: marker(asset, models), encoding: .utf8)
        return isInstalled(asset, in: models) && recorded == asset.version
    }

    private static func marker(_ asset: ModelAsset, _ models: URL) -> URL {
        models.appendingPathComponent("licenses/\(asset.name)/.sha256")
    }

    /// 下载压缩包到临时文件（调用方负责删除），`progress` 收到 0–1 的进度；取消任务即取消下载。
    /// HTTP 状态不是 200 时删掉临时文件并抛错
    /// Download the zip to a temporary file (the caller deletes it); `progress` gets 0–1; cancelling the task cancels
    /// the download. Non-200 responses delete the file and throw.
    ///
    /// # Examples
    /// ```
    /// let zip = try await ModelDownload.download(asset) { print($0) }
    /// ```
    public static func download(_ asset: ModelAsset,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: asset.url,
                                                                    delegate: ProgressReporter(progress))
        do {
            try checkStatus(response, asset.url)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    /// 校验 sha256 后用 ditto 解压安装：压缩包顶层的主文件放到 `installPath`，`birdtrace_class_map.json` 放根目录，
    /// `species_names.json` 进 `birdtrace/`，许可证等其余文件进 `licenses/<name>/`；同名旧文件被替换。
    /// 最后删掉该模型的编译缓存并写入版本标记（`version`）
    /// Verify the sha256, then unzip with ditto and install the zip's top-level items: the main item goes to
    /// `installPath`, `birdtrace_class_map.json` to the root, `species_names.json` to `birdtrace/`, licenses and the rest
    /// to `licenses/<name>/`; existing items of the same name are replaced. Finally the model's compiled cache is
    /// dropped and the version marker (`version`) written.
    ///
    /// # Examples
    /// ```
    /// try ModelDownload.install(zip, asset: asset, into: modelsDir)
    /// ```
    public static func install(_ zip: URL, asset: ModelAsset, into models: URL) throws {
        let digest = try PhotoImporter.sha256(of: zip)
        guard digest == asset.sha256.lowercased() else {
            throw RegulusError.model("\(asset.file): sha256 \(digest) != \(asset.sha256)")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        // 解压到同一卷上的临时目录，之后只需移动 / unzip next to the destination so installing is just a move
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: models,
                                 create: true)
        defer { try? fm.removeItem(at: staging) }
        try unzip(zip, to: staging)
        for item in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            try replace(at: destination(of: item.lastPathComponent, asset: asset, models: models), with: item)
        }
        // 解压保留了包内原有的修改时间，旧缓存可能看起来比新包还新，删掉以便重编
        // unzipping keeps the archived mtimes, so the old cache may look newer than the new package; drop it
        let compiled = (asset.package as NSString).deletingPathExtension + ".mlmodelc"
        try? fm.removeItem(at: models.appendingPathComponent("compiled/\(compiled)"))
        let marker = marker(asset, models)
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(asset.version.utf8).write(to: marker)
    }

    static func destination(of name: String, asset: ModelAsset, models: URL) -> URL {
        switch name {
        case asset.package: models.appendingPathComponent(asset.installPath)
        case "birdtrace_class_map.json": models.appendingPathComponent(name)
        case "species_names.json": models.appendingPathComponent("birdtrace/\(name)")
        default: models.appendingPathComponent("licenses/\(asset.name)/\(name)")
        }
    }

    private static func replace(at destination: URL, with item: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: item, to: destination)
    }

    private static func unzip(_ zip: URL, to directory: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, directory.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw RegulusError.model("unzip \(zip.lastPathComponent) failed (\(ditto.terminationStatus))")
        }
    }

    private static func checkStatus(_ response: URLResponse, _ url: URL) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw RegulusError.model("HTTP \(status): \(url.absoluteString)") }
    }
}

/// 把下载任务的进度转给回调 / Forwards a download task's progress to a callback.
final class ProgressReporter: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let observation = OSAllocatedUnfairLock<NSKeyValueObservation?>(uncheckedState: nil)

    init(_ onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observer = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
        observation.withLockUnchecked { $0 = observer }
    }
}
