import Foundation

/// 对照片跑检测、识鸟和评分。模型只在第一次分析时加载一次，之后复用
/// Runs detection, species ID and rating on photos. Models load once, on the first analysis, then are reused.
///
/// `repo` 下需要有 `Pipeline.packageNames` 各自的 `models/coreml/<名>_fp16.mlpackage` 及
/// `models/birdtrace_class_map.json`
/// `repo` must contain `models/coreml/<name>_fp16.mlpackage` for each of `Pipeline.packageNames` and
/// `models/birdtrace_class_map.json`.
///
/// # Examples
/// ```
/// let analyzer = PhotoAnalyzer(repo: appSupport)
/// let record = try await analyzer.analyze(photoURL, thresholds: .intermediate)
/// ```
public actor PhotoAnalyzer {
    public let repo: URL
    private var pipeline: Pipeline?

    public init(repo: URL) {
        self.repo = repo
    }

    /// 缺少的必需文件（相对 models/ 的路径，空数组表示齐全）
    /// Missing required files (paths relative to models/; empty means complete).
    public nonisolated var missingFiles: [String] {
        let models = repo.appendingPathComponent("models")
        let required = Pipeline.packageNames.values.map { "coreml/\($0)_fp16.mlpackage" }.sorted()
            + ["birdtrace_class_map.json"]
        return required.filter { !FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) }
    }

    /// 加载模型，已加载时直接返回（首次可能需要几秒编译）
    /// Load the models; no-op once loaded (the first time can take seconds to compile).
    ///
    /// # Examples
    /// ```
    /// try await analyzer.prepare()
    /// ```
    public func prepare() async throws {
        guard pipeline == nil else { return }
        pipeline = try await Pipeline(repo: repo)
    }

    /// 分析一张照片（必要时先加载模型，不做 ISO 折算）；regions 是识别的地区候选层（见 `RegionChecklist.tiers`），
    /// 空为不筛选。星级见 `record`
    /// Analyse one photo (loading the models if needed, no ISO discount); regions are the identification's regional
    /// candidate tiers (see `RegionChecklist.tiers`), empty means no filtering. See `record` for the stars.
    ///
    /// # Examples
    /// ```
    /// let rated = try await analyzer.analyze(url, thresholds: .intermediate, tasks: .rate)
    /// ```
    public func analyze(_ url: URL, thresholds: RatingThresholds, tasks: AnalysisTasks = .all,
                        regions: [Set<Int>] = []) async throws -> AnalysisRecord {
        try await prepare()
        guard let pipeline else { throw RegulusError.model("pipeline not loaded") }
        let metrics = PhotoMetrics(try pipeline.process(url, tasks: tasks, regions: regions))
        return Self.record(metrics, tasks: tasks, thresholds: thresholds)
    }

    /// 评分了才有星级；只识别时没找到鸟也记为「无鸟」（-1 星），找到鸟则评分留空
    /// Stars only when rating; identifying only records no bird as -1 and otherwise leaves the rating nil.
    static func record(_ metrics: PhotoMetrics, tasks: AnalysisTasks, thresholds: RatingThresholds) -> AnalysisRecord {
        let rated = tasks.contains(.rate) || !metrics.birdFound
        return AnalysisRecord(metrics: metrics, rating: rated ? RatingEngine.rate(metrics, thresholds: thresholds) : nil)
    }
}
