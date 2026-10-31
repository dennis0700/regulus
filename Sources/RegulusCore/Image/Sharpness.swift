import Foundation

/// SuperPicky 锐度算法的 Swift 移植（core/keypoint_detector.py、core/iso_sharpness.py）。
/// Swift port of SuperPicky's sharpness math (core/keypoint_detector.py, core/iso_sharpness.py).
public enum Sharpness {
    /// log 归一化下限 / lower bound of the log normalisation.
    public static let minVal = 100.0
    /// log 归一化上限 / upper bound of the log normalisation.
    public static let maxVal = 154_016.0
    /// 尺寸补偿系数（分/e 倍尺寸）/ size compensation (points per e-fold).
    public static let sizeCompK = 87.4
    /// 尺寸补偿参考边长（px）/ reference ROI side (px).
    public static let sizeCompRef = 300.0
    /// ISO 折算参数 / ISO discount parameters.
    public static let isoBase = 800.0, isoPenaltyFactor = 0.05, isoMinFactor = 0.5

    /// Tenengrad：3x3 Sobel 的 mean(gx²+gy²)，边界按 BORDER_REFLECT_101（cv2 默认）。
    /// mask（长度须为 width*height）只决定统计哪些像素，Sobel 邻域仍读取掩码外像素；没有像素被统计时返回 0。
    /// Tenengrad: mean(gx²+gy²) of 3x3 Sobel, BORDER_REFLECT_101 like cv2. The mask (length width*height) only
    /// selects which pixels are averaged; Sobel neighbourhoods still read unmasked pixels. 0 if nothing is counted.
    ///
    /// # Examples
    /// ```
    /// let flat = GrayImage(width: 4, height: 4, pixels: [UInt8](repeating: 9, count: 16))
    /// assert(Sharpness.tenengrad(flat) == 0)
    /// ```
    public static func tenengrad(_ img: GrayImage, mask: [Bool]? = nil) -> Double {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return 0 }
        var sum = 0.0
        var count = 0
        img.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let ym = reflect(y - 1, h), yp = reflect(y + 1, h)
                for x in 0..<w {
                    if let mask, !mask[y * w + x] { continue }
                    let xm = reflect(x - 1, w), xp = reflect(x + 1, w)
                    func v(_ yy: Int, _ xx: Int) -> Float { Float(p[yy * w + xx]) }
                    let gx = (v(ym, xp) + 2 * v(y, xp) + v(yp, xp)) - (v(ym, xm) + 2 * v(y, xm) + v(yp, xm))
                    let gy = (v(yp, xm) + 2 * v(yp, x) + v(yp, xp)) - (v(ym, xm) + 2 * v(ym, x) + v(ym, xp))
                    sum += Double(gx * gx + gy * gy)
                    count += 1
                }
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// 原始 Tenengrad → 0-1000 log 分（SuperPicky `_calculate_sharpness` 的归一化段）。
    /// Raw Tenengrad -> 0-1000 log score (normalisation part of SuperPicky `_calculate_sharpness`).
    ///
    /// # Examples
    /// ```
    /// assert(Sharpness.logNormalize(100) == 0)
    /// assert(Sharpness.logNormalize(200_000) == 1000)
    /// ```
    public static func logNormalize(_ raw: Double) -> Double {
        if raw <= minVal { return 0 }
        if raw >= maxVal { return 1000 }
        return (log(raw) - log(minVal)) / (log(maxVal) - log(minVal)) * 1000
    }

    /// 小 ROI 虚高扣除：边长 < 300 时减去 87.4·ln(300/边长)，只减不加，下限 0。
    /// Small-ROI inflation removal: below a 300 px side, subtract 87.4·ln(300/side); downward only, floor 0.
    ///
    /// # Examples
    /// ```
    /// assert(Sharpness.sizeCompensation(500, roiSide: 300) == 500)
    /// ```
    public static func sizeCompensation(_ score: Double, roiSide: Int) -> Double {
        let side = Double(roiSide)
        guard sizeCompK > 0, roiSide > 0, side < sizeCompRef else { return score }
        return max(0, score - sizeCompK * log(sizeCompRef / side))
    }

    /// ISO 折算系数：ISO 800 以上每翻倍扣 5%，最低 0.5 / ISO factor: -5% per doubling above 800, floor 0.5.
    ///
    /// # Examples
    /// ```
    /// assert(Sharpness.isoFactor(1600) == 0.95)
    /// ```
    public static func isoFactor(_ iso: Double?) -> Double {
        guard let iso, iso > isoBase else { return 1 }
        return max(isoMinFactor, 1 - isoPenaltyFactor * log2(iso / isoBase))
    }

    /// BORDER_REFLECT_101 下标映射，只处理越界 1 格（3x3 核够用）。
    /// BORDER_REFLECT_101 index mapping; handles at most 1 step out of range (enough for a 3x3 kernel).
    @inline(__always)
    static func reflect(_ i: Int, _ n: Int) -> Int {
        if n == 1 { return 0 }
        if i < 0 { return -i }
        if i >= n { return 2 * n - 2 - i }
        return i
    }
}
