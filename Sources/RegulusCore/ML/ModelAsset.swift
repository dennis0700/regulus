import Foundation

/// superpicky-coreml 发布页上的一个模型或数据压缩包（manifest.json 中 "models" 或 "data" 的一项）
/// One model or data zip on the superpicky-coreml release page (an entry of "models" or "data" in manifest.json).
public struct ModelAsset: Codable, Sendable, Identifiable, Equatable {
    public let name: String
    public let file: String
    /// 压缩包里的主文件：模型为 mlpackage（如 "birdtrace_fp16.mlpackage"），数据包为数据文件（如 "regions.json"）
    /// The zip's main item: the mlpackage for a model (e.g. "birdtrace_fp16.mlpackage"), the data file for a data
    /// package (e.g. "regions.json").
    public let package: String
    /// 压缩包字节数与 sha256 / Byte size and sha256 of the zip.
    public let size: Int64
    public let sha256: String
    /// 压缩包里除 SOURCE.txt 外各文件的内容哈希：只换了提交号时不变；较早的清单没有
    /// Content hash of the zip's files except SOURCE.txt: unchanged when only the commit changed; absent from older
    /// manifests.
    public var contentSha256: String? = nil
    public let license: String
    public let upstream: String
    public let url: URL

    public var id: String { name }

    /// 判断是否最新用的版本号：有内容哈希用它，否则用压缩包的 sha256（小写）
    /// The version used to tell whether an install is current: the content hash if present, else the zip's sha256
    /// (lower-cased).
    public var version: String {
        (contentSha256 ?? sha256).lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case name, file, package, size, sha256, license, upstream, url
        case contentSha256 = "content_sha256"
    }

    /// 主文件安装后相对 models/ 的路径：mlpackage 进 `coreml/`，数据文件放根目录
    /// Where the main item is installed, relative to models/: mlpackages in `coreml/`, data files at the root.
    public var installPath: String {
        package.hasSuffix(".mlpackage") ? "coreml/\(package)" : package
    }
}
