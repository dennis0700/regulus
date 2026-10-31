import Foundation

/// 一次分析要做的事：评分（关键点、头部锐度、飞版、美学）和 / 或识别鸟种（BirdTrace）；解码和 YOLO 找鸟两者都要
/// What one analysis does: rating (keypoints, head sharpness, flight, aesthetics) and/or species ID (BirdTrace);
/// decoding and YOLO bird detection are needed by both.
public struct AnalysisTasks: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let rate = AnalysisTasks(rawValue: 1 << 0)
    public static let identify = AnalysisTasks(rawValue: 1 << 1)
    public static let all: AnalysisTasks = [.rate, .identify]
}

/// 一张照片的分析结果；不保存，星级和鸟种由 App 写进照片文件
/// Analysis result of one photo; not stored: the app writes the stars and species into the photo file.
public struct AnalysisRecord: Sendable, Equatable {
    public let metrics: PhotoMetrics
    /// 只识别、没评分时为 nil / nil when the photo was identified but not rated.
    public let rating: Rating?

    public init(metrics: PhotoMetrics, rating: Rating?) {
        self.metrics = metrics
        self.rating = rating
    }
}
