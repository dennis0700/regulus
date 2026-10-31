import Foundation

/// BirdTrace 输出处理：softmax、类别映射累加、top-k / BirdTrace post-processing: softmax, class-map sum, top-k.
public struct BirdTraceHead: Sendable {
    /// BirdTrace 输出下标 → 鸟种库类别号（-1 = 未映射）/ BirdTrace output index -> species-DB id (-1 = unmapped).
    public let classMap: [Int]
    /// 鸟种库类别数，与 species_names.json 条数一致 / Number of species-DB ids, same as entries in species_names.json.
    public static let numDBClasses = 10964

    /// 从 birdtrace_class_map.json 的 "class_map" 数组加载 / Load the "class_map" array of birdtrace_class_map.json.
    ///
    /// # Examples
    /// ```
    /// let head = try BirdTraceHead(classMap: mapURL)
    /// ```
    public init(classMap: URL) throws {
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: classMap)) as? [String: Any]
        guard let map = m?["class_map"] as? [Int] else { throw RegulusError.model("bad class map") }
        self.classMap = map
    }

    /// 直接给定映射（测试用）/ Build from an explicit map (tests).
    public init(classMap: [Int]) {
        self.classMap = classMap
    }

    /// 数值稳定 softmax（减最大值，Double 累加）；空输入返回空。
    /// Numerically stable softmax (max-subtracted, Double sums); empty in, empty out.
    ///
    /// # Examples
    /// ```
    /// let p = BirdTraceHead.softmax([1, 2, 3])
    /// ```
    public static func softmax(_ logits: [Float]) -> [Double] {
        guard let m = logits.max() else { return [] }
        let e = logits.map { exp(Double($0 - m)) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }

    /// 概率按 classMap 累加到 numDBClasses 个鸟种库类别（多对一相加；未映射或越界的丢弃）。
    /// Sum probabilities onto the numDBClasses species-DB ids via classMap (many-to-one; unmapped or out of range
    /// entries dropped).
    ///
    /// # Examples
    /// ```
    /// let db = head.aggregate(probs)
    /// ```
    public func aggregate(_ probs: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: Self.numDBClasses)
        for (i, c) in classMap.enumerated() where c >= 0 && c < Self.numDBClasses && i < probs.count {
            out[c] += probs[i]
        }
        return out
    }

    /// 最大的 k 个下标，按值降序，同值时小下标在前 / Indices of the k largest values, descending; ties by index.
    ///
    /// # Examples
    /// ```
    /// assert(BirdTraceHead.topk([0.1, 0.7, 0.2], 2) == [1, 2])
    /// ```
    public static func topk(_ xs: [Double], _ k: Int) -> [Int] {
        Array(xs.indices.sorted { xs[$0] != xs[$1] ? xs[$0] > xs[$1] : $0 < $1 }.prefix(k))
    }

    /// 按地区筛选时候选鸟种的最低概率（同 SuperPicky 的 0.3%）/ Minimum probability of a candidate when filtering by
    /// region (0.3%, as SuperPicky).
    public static let minRegionalProb = 0.003

    /// 最可能的鸟种。tiers 为空时取全部鸟种的 top-1（概率为 0 时为 nil）；否则逐层取层内概率最高、
    /// 且不低于 minRegionalProb 的鸟种，命中即停，各层都没有时为 nil。同概率时小下标优先。
    /// The most likely species. With no tiers, the top-1 over all species (nil if its probability is 0); otherwise
    /// tier by tier the most likely species in the tier at or above minRegionalProb, stopping at the first hit; nil
    /// if no tier has one. Ties go to the smaller index.
    ///
    /// # Examples
    /// ```
    /// assert(BirdTraceHead.best([0.5, 0.3, 0.2], tiers: [[1, 2]]) == 1)
    /// ```
    public static func best(_ xs: [Double], tiers: [Set<Int>]) -> Int? {
        guard !tiers.isEmpty else { return topk(xs, 1).first.flatMap { xs[$0] > 0 ? $0 : nil } }
        for tier in tiers {
            let ids = tier.filter { xs.indices.contains($0) && xs[$0] >= minRegionalProb }
            if let id = ids.max(by: { xs[$0] != xs[$1] ? xs[$0] < xs[$1] : $0 > $1 }) { return id }
        }
        return nil
    }
}

/// SuperEyes 关键点结果 / SuperEyes keypoint result.
public struct Keypoints: Sendable {
    /// [左眼, 右眼, 喙] 的 (x, y)，相对裁剪图归一化 / (x, y) of [left eye, right eye, beak], normalised to the crop.
    public var coords: [[Double]]
    /// [左眼, 右眼, 喙] 的可见度 / Visibility of [left eye, right eye, beak].
    public var vis: [Double]

    /// 由模型输出构造（coords [1,3,2]、vis [1,3] 展平后的数组）；coords 少于 6 个元素会越界崩溃。
    /// Build from flattened model outputs (coords [1,3,2], vis [1,3]); coords with fewer than 6 values traps.
    ///
    /// # Examples
    /// ```
    /// let kp = Keypoints(coords: out["coords"]!, vis: out["vis"]!)
    /// ```
    public init(coords: [Float], vis: [Float]) {
        self.coords = (0..<3).map { [Double(coords[$0 * 2]), Double(coords[$0 * 2 + 1])] }
        self.vis = vis.prefix(3).map(Double.init)
    }
}

/// SuperPicky 头部锐度（keypoint_detector._calculate_head_sharpness）的移植。
/// Port of SuperPicky head sharpness (keypoint_detector._calculate_head_sharpness).
public enum HeadSharpness {
    /// 可见阈值、眼喙半径倍数、无喙时半径占框边比例、双眼不可见惩罚
    /// Visibility cut, eye-beak radius multiplier, radius/box-side ratio without a beak, both-eyes-hidden penalty.
    public static let visibility = 0.3, radiusMultiplier = 1.2, noBeakRatio = 0.15, lowVisPenalty = 0.8

    /// 选眼：双眼都可见取离喙更远的，只一只可见取它，都不可见取可见度高的。
    /// 半径：喙可见时为眼喙像素距离 ×1.2，否则 boxSide（nil 时用裁剪图长边）×0.15；上限短边/2，下限 10（下限优先）。
    /// 圆 ∩ segMask（长度不等于 w*h 时忽略）的外接矩形上做 Tenengrad（只统计圆内像素），
    /// 经 log 归一化（0–1000）和尺寸补偿，双眼都不可见再 ×0.8，最后乘 ISO 系数；圆为空时分数为 0。
    /// 返回分数、半径和眼睛像素坐标。
    /// Eye: the one farther from the beak if both are visible, the visible one if only one is, else the more
    /// visible. Radius: eye-beak pixel distance x1.2 if the beak is visible, else boxSide (or the crop's long side)
    /// x0.15; capped at short side / 2, floored at 10 (the floor wins). Tenengrad over the bounding rect of
    /// circle ∩ segMask (ignored if its length is not w*h), counting only circle pixels; log-normalised (0–1000),
    /// size-compensated, x0.8 if both eyes are hidden, then times the ISO factor; 0 if the circle is empty.
    /// Returns the score, the radius and the eye's pixel position.
    ///
    /// # Examples
    /// ```
    /// let s = HeadSharpness.compute(crop: crop, keypoints: kp, boxSide: 200, segMask: nil, iso: 400)
    /// ```
    public static func compute(crop: RGBA8Buffer, keypoints kp: Keypoints, boxSide: Int?, segMask: [Bool]?,
                               iso: Double?) -> (score: Double, radius: Int, eye: [Int]) {
        let w = crop.width, h = crop.height
        let le = kp.coords[0], re = kp.coords[1], beak = kp.coords[2]
        let lv = kp.vis[0] >= visibility, rv = kp.vis[1] >= visibility, bv = kp.vis[2] >= visibility
        let eye: [Double]
        if !lv && !rv {
            eye = kp.vis[0] >= kp.vis[1] ? le : re
        } else if lv && rv {
            eye = dist(le, beak) >= dist(re, beak) ? le : re
        } else {
            eye = lv ? le : re
        }
        let ex = Int(eye[0] * Double(w)), ey = Int(eye[1] * Double(h))
        let bx = Int(beak[0] * Double(w)), by = Int(beak[1] * Double(h))
        var radius: Int
        if bv {
            radius = Int(dist([Double(ex), Double(ey)], [Double(bx), Double(by)]) * radiusMultiplier)
        } else if let boxSide {
            radius = Int(Double(boxSide) * noBeakRatio)
        } else {
            radius = Int(Double(max(w, h)) * noBeakRatio)
        }
        radius = max(10, min(radius, min(w, h) / 2))
        // 近似 cv2.circle 填充圆：整数像素到圆心距离 <= r / approximates a filled cv2.circle: integer pixel within r
        var mask = [Bool](repeating: false, count: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        let r2 = radius * radius
        // stride 在下界大于上界时为空（眼睛落在图外不会崩溃）/ stride is empty when the eye is outside the crop
        for y in stride(from: max(0, ey - radius), through: min(h - 1, ey + radius), by: 1) {
            for x in stride(from: max(0, ex - radius), through: min(w - 1, ex + radius), by: 1) {
                let dx = x - ex, dy = y - ey
                guard dx * dx + dy * dy <= r2 else { continue }
                if let segMask, segMask.count == w * h, !segMask[y * w + x] { continue }
                mask[y * w + x] = true
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return (0, radius, [ex, ey]) }
        let rw = maxX - minX + 1, rh = maxY - minY + 1
        let roi = GrayImage(rgba: crop.cropped(x: minX, y: minY, w: rw, h: rh))
        var roiMask = [Bool](repeating: false, count: rw * rh)
        for y in 0..<rh { for x in 0..<rw { roiMask[y * rw + x] = mask[(y + minY) * w + x + minX] } }
        let raw = Sharpness.tenengrad(roi, mask: roiMask)
        var score = Sharpness.sizeCompensation(Sharpness.logNormalize(raw), roiSide: max(rw, rh))
        if !lv && !rv { score *= lowVisPenalty }
        return (score * Sharpness.isoFactor(iso), radius, [ex, ey])
    }

    static func dist(_ a: [Double], _ b: [Double]) -> Double {
        ((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1])).squareRoot()
    }
}
