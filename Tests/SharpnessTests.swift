import Foundation
import Testing
@testable import RegulusCore

/// 生成棋盘格灰度图 / Build a checkerboard gray image.
func checkerboard(_ n: Int, cell: Int) -> GrayImage {
    var px = [UInt8](repeating: 0, count: n * n)
    for y in 0..<n { for x in 0..<n where ((x / cell) + (y / cell)) % 2 == 0 { px[y * n + x] = 255 } }
    return GrayImage(width: n, height: n, pixels: px)
}

/// 3x3 盒式模糊若干次（近似高斯）/ Repeated 3x3 box blur (approximates a Gaussian).
func blurred(_ img: GrayImage, passes: Int) -> GrayImage {
    var cur = img.pixels.map(Double.init)
    let w = img.width, h = img.height
    for _ in 0..<passes {
        var next = cur
        for y in 0..<h { for x in 0..<w {
            var s = 0.0
            for dy in -1...1 { for dx in -1...1 {
                s += cur[Sharpness.reflect(y + dy, h) * w + Sharpness.reflect(x + dx, w)]
            } }
            next[y * w + x] = s / 9
        } }
        cur = next
    }
    return GrayImage(width: w, height: h, pixels: cur.map { UInt8(max(0, min(255, $0.rounded()))) })
}

@Test func flatImageHasZeroSharpness() {
    let flat = GrayImage(width: 32, height: 32, pixels: [UInt8](repeating: 77, count: 1024))
    #expect(Sharpness.tenengrad(flat) == 0)
}

@Test func checkerboardSharperThanBlurred() {
    let sharp = checkerboard(64, cell: 4)
    let soft = blurred(sharp, passes: 3)
    #expect(Sharpness.tenengrad(sharp) > Sharpness.tenengrad(soft) * 2)
}

@Test func sobelMatchesHandComputedStepEdge() {
    // 垂直台阶 0|255：边缘两列 gx = 4*255，cv2 同值 / vertical step edge: gx = 4*255 on the two edge columns
    let w = 6, h = 4
    let px = (0..<(w * h)).map { $0 % w >= 3 ? UInt8(255) : 0 }
    let t = Sharpness.tenengrad(GrayImage(width: w, height: h, pixels: px))
    #expect(abs(t - Double(2 * h) * pow(4 * 255, 2) / Double(w * h)) < 1e-6)
}

@Test func maskRestrictsTenengrad() {
    let img = checkerboard(16, cell: 8)
    var mask = [Bool](repeating: false, count: 256)
    mask[0] = true  // 角落像素在平坦区内 / corner pixel lies in a flat cell
    #expect(Sharpness.tenengrad(img, mask: mask) == 0)
}

@Test func logNormalizationMatchesPythonFormula() {
    #expect(Sharpness.logNormalize(50) == 0)
    #expect(Sharpness.logNormalize(100) == 0)
    #expect(Sharpness.logNormalize(154_016) == 1000)
    let mid = 1000 * (log(5000.0) - log(100.0)) / (log(154_016.0) - log(100.0))
    #expect(abs(Sharpness.logNormalize(5000) - mid) < 1e-9)
}

@Test func sizeCompensationEdgeCases() {
    #expect(Sharpness.sizeCompensation(500, roiSide: 300) == 500)
    #expect(Sharpness.sizeCompensation(500, roiSide: 1000) == 500)
    #expect(Sharpness.sizeCompensation(500, roiSide: 0) == 500)
    #expect(abs(Sharpness.sizeCompensation(500, roiSide: 150) - (500 - 87.4 * log(2.0))) < 1e-9)
    #expect(Sharpness.sizeCompensation(10, roiSide: 5) == 0)
}

@Test func isoFactorMatchesSuperPicky() {
    #expect(Sharpness.isoFactor(nil) == 1)
    #expect(Sharpness.isoFactor(800) == 1)
    #expect(abs(Sharpness.isoFactor(3200) - 0.9) < 1e-12)
    #expect(Sharpness.isoFactor(102_400 * 1024) == 0.5)
}

@Test func grayConversionUsesOpenCVWeights() {
    let rgba = RGBA8Buffer(width: 3, height: 1, bytes: [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255])
    // cv2.cvtColor RGB2GRAY: red 76, green 150, blue 29
    #expect(GrayImage(rgba: rgba).pixels == [76, 150, 29])
}
