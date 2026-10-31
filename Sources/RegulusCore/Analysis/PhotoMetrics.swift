import Foundation

/// 评分需要的原始指标，来自一次模型分析 / Raw metrics from one model run.
public struct PhotoMetrics: Codable, Sendable, Equatable {
    public var birdFound: Bool
    public var birdConfidence: Double?
    /// [左眼, 右眼, 喙] 的可见度 / Visibility of [left eye, right eye, beak].
    public var keypointVisibility: [Double]?
    /// 头部锐度（0–1000 log 分，已含尺寸补偿、双眼不可见 ×0.8 与 ISO 折算）
    /// Head sharpness (0–1000 log score, with size compensation, the x0.8 both-eyes-hidden penalty and ISO factor).
    public var headSharpness: Double?
    /// TOPIQ 美学分（1–10）/ TOPIQ aesthetics (1–10).
    public var aesthetics: Double?
    public var flightProbability: Double?
    /// 鸟种库类别号及概率 / Species-DB id and its probability.
    public var speciesId: Int?
    public var speciesProbability: Double?

    public init(birdFound: Bool, birdConfidence: Double? = nil, keypointVisibility: [Double]? = nil,
                headSharpness: Double? = nil, aesthetics: Double? = nil, flightProbability: Double? = nil,
                speciesId: Int? = nil, speciesProbability: Double? = nil) {
        self.birdFound = birdFound
        self.birdConfidence = birdConfidence
        self.keypointVisibility = keypointVisibility
        self.headSharpness = headSharpness
        self.aesthetics = aesthetics
        self.flightProbability = flightProbability
        self.speciesId = speciesId
        self.speciesProbability = speciesProbability
    }

    /// 从流水线结果取出要保存的指标 / Take the metrics to store from a pipeline result.
    ///
    /// # Examples
    /// ```
    /// let metrics = PhotoMetrics(try pipeline.process(url))
    /// ```
    public init(_ result: PipelineResult) {
        self.init(birdFound: result.birdFound, birdConfidence: result.birdConf, keypointVisibility: result.keypoints?.vis,
                  headSharpness: result.headSharpness, aesthetics: result.topiq, flightProbability: result.flightProb,
                  speciesId: result.speciesId, speciesProbability: result.speciesIdProb)
    }

    /// 飞版判定，同 SuperPicky 的 prob > 0.5 / Flight decision, prob > 0.5 as in SuperPicky.
    public var isFlying: Bool { (flightProbability ?? 0) > RatingEngine.flightThreshold }
}
