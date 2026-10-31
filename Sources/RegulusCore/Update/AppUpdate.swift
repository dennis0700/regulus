import Foundation

/// GitHub 上 regulus 最新 Release 里的 App 安装包（`Regulus.zip`）
/// The app package (`Regulus.zip`) in the latest regulus release on GitHub.
public struct AppRelease: Sendable, Equatable {
    /// 去掉开头 `v` 的 tag，如 "0.2.0" / The tag without its leading `v`, e.g. "0.2.0".
    public let version: String
    /// Release 说明（Markdown）/ Release notes (Markdown).
    public let notes: String
    public let page: URL
    public let asset: URL
    public let size: Int64
    /// GitHub 给出的 asset sha256（小写十六进制）/ The asset's sha256 reported by GitHub (lowercase hex).
    public let sha256: String
}

/// 从 GitHub Release 更新 App：检查版本、下载校验、退出后替换 App 并重新打开
/// Update the app from GitHub releases: check the version, download and verify, then swap the app after it quits
/// and reopen it.
///
/// 发布约定：tag 为 `v<CFBundleShortVersionString>`，附件 `Regulus.zip` 由 `ditto -c -k --keepParent` 打包（见
/// scripts/package.sh）。
/// Release convention: the tag is `v<CFBundleShortVersionString>` and the `Regulus.zip` asset is made with
/// `ditto -c -k --keepParent` (see scripts/package.sh).
public enum AppUpdate {
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/dennis0700/regulus/releases/latest")!
    public static let assetName = "Regulus.zip"

    private struct Release: Decodable {
        let tagName: String
        let body: String?
        let htmlUrl: URL
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
        let size: Int64
        /// 形如 "sha256:<hex>" / Like "sha256:<hex>".
        let digest: String?
    }

    /// 解析 GitHub `releases/latest` 的 JSON / Decode the JSON of GitHub's `releases/latest`.
    ///
    /// - Throws: `RegulusError.update`（没有 `Regulus.zip` 或它没有 sha256）、`DecodingError`
    ///   / `RegulusError.update` (no `Regulus.zip`, or it has no sha256), `DecodingError`.
    ///
    /// # Examples
    /// ```
    /// let release = try AppUpdate.decodeRelease(data)
    /// print(release.version)   // "0.2.0"
    /// ```
    public static func decodeRelease(_ data: Data) throws -> AppRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name == assetName }) else {
            throw RegulusError.update("release \(release.tagName) has no \(assetName)")
        }
        guard let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw RegulusError.update("\(assetName) in \(release.tagName) has no sha256 digest")
        }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return AppRelease(version: version, notes: release.body ?? "", page: release.htmlUrl,
                          asset: asset.browserDownloadUrl, size: asset.size,
                          sha256: digest.dropFirst("sha256:".count).lowercased())
    }

    /// 读取最新 Release（不含草稿和预发布），HTTP 状态不是 200 时抛错（还没有任何 Release 时是 404）
    /// Fetch the latest release (drafts and prereleases excluded); throws unless HTTP 200 (404 while there is none).
    ///
    /// # Examples
    /// ```
    /// let release = try await AppUpdate.fetchLatest()
    /// ```
    public static func fetchLatest(from url: URL = latestReleaseAPI) async throws -> AppRelease {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, url)
        return try decodeRelease(data)
    }

    /// 按数字逐段比较版本号（"0.10.0" 比 "0.9.1" 新，缺的段按 0）；非数字段按 0
    /// Compare versions numerically, segment by segment ("0.10.0" is newer than "0.9.1", missing segments count as
    /// 0); non-numeric segments count as 0.
    ///
    /// # Examples
    /// ```
    /// AppUpdate.isNewer("0.2.0", than: "0.1.9")   // true
    /// AppUpdate.isNewer("1.0", than: "1.0.0")     // false
    /// ```
    public static func isNewer(_ version: String, than current: String) -> Bool {
        let new = version.split(separator: ".").map { Int($0) ?? 0 }
        let old = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// 下载安装包到临时文件（调用方负责删除），`progress` 收到 0–1；取消任务即取消下载
    /// Download the package to a temporary file (the caller deletes it); `progress` gets 0–1; cancelling the task
    /// cancels the download.
    ///
    /// # Examples
    /// ```
    /// let zip = try await AppUpdate.download(release) { print($0) }
    /// ```
    public static func download(_ release: AppRelease,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: release.asset,
                                                                    delegate: ProgressReporter(progress))
        do {
            try checkStatus(response, release.asset)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    /// 校验 sha256，解压到与 `app` 同一卷的临时目录，并确认里面的 App 与 `app` 的 bundle id 相同、版本号就是
    /// Release 的版本。返回解压出的新 App
    /// Verify the sha256, unzip next to `app` (same volume), and check that the app inside has `app`'s bundle id and
    /// the release's version. Returns the unzipped app.
    ///
    /// - Throws: `RegulusError.update`：哈希不符、`app` 所在文件夹不可写（如未移到「应用程序」时的只读位置）、
    ///   解压失败或包内容不对 / hash mismatch, `app`'s folder is not writable (e.g. the read-only location of an
    ///   app that was never moved to Applications), unzip failure, or wrong contents.
    ///
    /// # Examples
    /// ```
    /// let newApp = try AppUpdate.prepare(zip, release: release, replacing: Bundle.main.bundleURL)
    /// ```
    public static func prepare(_ zip: URL, release: AppRelease, replacing app: URL) throws -> URL {
        let digest = try PhotoImporter.sha256(of: zip)
        guard digest == release.sha256 else {
            throw RegulusError.update("\(assetName): sha256 \(digest) != \(release.sha256)")
        }
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else {
            throw RegulusError.update("no write permission to \(folder.path)")
        }
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app,
                                 create: true)
        do {
            try unzip(zip, to: staging)
            let found = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "app" }
            guard let newApp = found else { throw RegulusError.update("\(assetName) contains no app") }
            let (newID, newVersion) = bundleInfo(newApp)
            guard newID != nil, newID == bundleInfo(app).id, newVersion == release.version else {
                throw RegulusError.update("\(assetName) is \(newID ?? "?") \(newVersion ?? "?"), expected \(release.version)")
            }
            return newApp
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// 启动一个后台 sh：等当前进程退出后把 `app` 换成 `newApp`（换失败就放回旧版），删掉临时目录，再打开 `app`。
    /// 调用后应立即退出 App
    /// Start a background sh that waits for this process to exit, swaps `app` for `newApp` (restoring the old one if
    /// that fails), removes the temp folder and reopens `app`. Quit the app right after calling this.
    ///
    /// # Examples
    /// ```
    /// try AppUpdate.installAfterExit(newApp, replacing: Bundle.main.bundleURL)
    /// NSApp.terminate(nil)
    /// ```
    public static func installAfterExit(_ newApp: URL, replacing app: URL) throws {
        let staging = newApp.deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 路径作为位置参数传入，不拼进脚本 / paths are passed as positional arguments, never spliced into the script
        process.arguments = ["-c", installScript, "sh", String(ProcessInfo.processInfo.processIdentifier),
                             app.path, newApp.path, staging.path]
        try process.run()
    }

    /// $1 进程号，$2 旧 App，$3 新 App，$4 临时目录（旧 App 先挪进去，成功后连同目录一起删）
    /// $1 pid, $2 old app, $3 new app, $4 temp folder (the old app moves in first and goes with it on success).
    static let installScript = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$2" "$4/previous.app"; then
          if mv "$3" "$2"; then rm -rf "$4"; else mv "$4/previous.app" "$2"; fi
        fi
        open "$2"
        """

    private static func bundleInfo(_ app: URL) -> (id: String?, version: String?) {
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return (plist?["CFBundleIdentifier"] as? String, plist?["CFBundleShortVersionString"] as? String)
    }

    private static func unzip(_ zip: URL, to directory: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, directory.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw RegulusError.update("unzip \(zip.lastPathComponent) failed (\(ditto.terminationStatus))")
        }
    }

    private static func checkStatus(_ response: URLResponse, _ url: URL) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw RegulusError.update("HTTP \(status): \(url.absoluteString)") }
    }
}
