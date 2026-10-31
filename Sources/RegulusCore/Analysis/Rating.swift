import Foundation

/// 星级：-1 无鸟，0–3 星 / Stars: -1 = no bird, 0–3 stars.
public struct Rating: Codable, Sendable, Equatable {
    public let stars: Int
    /// 给人看的原因 / Human-readable reason.
    public let reason: String
}

/// 锐度 / 美学的达标阈值（都达标 3 星，达标一项 2 星）；`intermediate` 为 SuperPicky 中级预设
/// Sharpness / aesthetics pass thresholds (both pass = 3 stars, one = 2); `intermediate` is SuperPicky's preset.
public struct RatingThresholds: Codable, Sendable, Equatable {
    public let sharpness: Double
    public let aesthetics: Double

    public static let intermediate = RatingThresholds(sharpness: 380, aesthetics: 4.8)
}

/// SuperPicky `core/rating_engine.py` `RatingEngine.calculate` 的移植
/// Port of SuperPicky `core/rating_engine.py` `RatingEngine.calculate`.
///
/// 未移植：曝光降级、对焦点权重（固定为 1.0，即"对焦在鸟身"）、SuperPicky 4.8 的分位配额与 v2 门控
/// Not ported: exposure downgrade, AF-point weights (fixed at 1.0, "focus on the bird"), and SuperPicky 4.8's
/// percentile quota and v2 gate.
public enum RatingEngine {
    /// 低于这些下限直接 0 星 / Below these floors the photo gets 0 stars.
    public static let minConfidence = 0.5
    public static let minSharpness = 100.0
    public static let minAesthetics = 3.5
    /// 三个关键点都低于此值时 1 星 / 1 star when all three keypoints are below this.
    public static let keypointVisible = 0.3
    public static let flightThreshold = 0.5
    /// 飞鸟加成：锐度 ×1.2，美学 ×1.1 / Flight bonus: sharpness ×1.2, aesthetics ×1.1.
    public static let flightSharpnessBonus = 1.2, flightAestheticsBonus = 1.1

    /// 计算星级，按顺序判定：无鸟 -1；置信度 < 0.5 → 0；三个关键点可见度都 < 0.3 → 1；锐度 < 100（缺失按 0）→ 0；
    /// 美学 < 3.5 → 0（缺失不判）；其余按阈值得 1–3 星，飞版先给锐度 ×1.2、美学 ×1.1，
    /// 再乘眼睛可见度权重 clamp(较高眼可见度 ×2, 0.5, 1) 并四舍六入五成双（所以可能降到 0 星）。
    /// Compute the stars, checked in order: no bird -1; confidence < 0.5 -> 0; all three keypoint visibilities
    /// < 0.3 -> 1; sharpness < 100 (missing = 0) -> 0; aesthetics < 3.5 -> 0 (skipped if missing); otherwise 1–3
    /// stars from the thresholds, with flight boosting sharpness x1.2 and aesthetics x1.1, then times the eye weight
    /// clamp(best eye visibility x2, 0.5, 1) rounded half to even (so it can drop to 0).
    ///
    /// # Examples
    /// ```
    /// let m = PhotoMetrics(birdFound: true, birdConfidence: 0.9, keypointVisibility: [0.9, 0.2, 0.8],
    ///                      headSharpness: 450, aesthetics: 5.2)
    /// RatingEngine.rate(m, thresholds: .intermediate).stars   // 3
    /// ```
    public static func rate(_ m: PhotoMetrics, thresholds: RatingThresholds) -> Rating {
        guard m.birdFound else { return Rating(stars: -1, reason: "未检测到鸟") }
        if (m.birdConfidence ?? 0) < minConfidence {
            return Rating(stars: 0, reason: "检测置信度低")
        }
        let visibility = m.keypointVisibility ?? []
        if !visibility.isEmpty, visibility.allSatisfy({ $0 < keypointVisible }) {
            return Rating(stars: 1, reason: "看不到眼睛和鸟喙")
        }
        let sharpness = m.headSharpness ?? 0
        if sharpness < minSharpness {
            return Rating(stars: 0, reason: "头部锐度过低")
        }
        if let aesthetics = m.aesthetics, aesthetics < minAesthetics {
            return Rating(stars: 0, reason: "美学评分过低")
        }
        return Rating(stars: stars(m, sharpness: sharpness, thresholds: thresholds), reason: reason(m, sharpness, thresholds))
    }

    static func adjusted(_ m: PhotoMetrics, sharpness: Double) -> (sharpness: Double, aesthetics: Double?) {
        guard m.isFlying else { return (sharpness, m.aesthetics) }
        return (sharpness * flightSharpnessBonus, m.aesthetics.map { $0 * flightAestheticsBonus })
    }

    static func stars(_ m: PhotoMetrics, sharpness: Double, thresholds: RatingThresholds) -> Int {
        let (s, a) = adjusted(m, sharpness: sharpness)
        let sharpOK = s >= thresholds.sharpness
        let aestheticsOK = a.map { $0 >= thresholds.aesthetics } ?? false
        let base = sharpOK && aestheticsOK ? 3 : (sharpOK || aestheticsOK ? 2 : 1)
        // 眼睛可见度渐进降权（没有关键点时权重为 1）；Python 的 round() 是四舍六入五成双，这里保持一致
        // Progressive eye-visibility weight (1 without keypoints); Python's round() rounds half to even, matched here.
        let visibility = m.keypointVisibility ?? []
        let bestEye = visibility.count >= 2 ? max(visibility[0], visibility[1]) : 1
        let weight = max(0.5, min(1.0, bestEye * 2))
        return Int((Double(base) * weight).rounded(.toNearestOrEven))
    }

    static func reason(_ m: PhotoMetrics, _ sharpness: Double, _ thresholds: RatingThresholds) -> String {
        let (s, a) = adjusted(m, sharpness: sharpness)
        let sharpOK = s >= thresholds.sharpness
        let aestheticsOK = a.map { $0 >= thresholds.aesthetics } ?? false
        var parts: [String]
        switch (sharpOK, aestheticsOK) {
        case (true, true): parts = ["锐度和美学都达标"]
        case (true, false): parts = ["锐度达标"]
        case (false, true): parts = ["美学达标"]
        case (false, false): parts = ["锐度和美学都未达标"]
        }
        if m.isFlying { parts.append("飞版加成") }
        let visibility = m.keypointVisibility ?? []
        if visibility.count >= 2, max(visibility[0], visibility[1]) < 0.5 { parts.append("眼睛可见度低") }
        return parts.joined(separator: "，")
    }
}
