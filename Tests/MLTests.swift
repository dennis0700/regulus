import CoreML
import Foundation
import Testing
@testable import RegulusCore

func det(_ box: [Double], _ conf: Double, _ cls: Int = 14) -> Detection {
    Detection(box: box, conf: conf, cls: cls, coeffs: [Float](repeating: 0, count: 32))
}

@Test func nmsSuppressesOverlapsWithinClassOnly() {
    let kept = YOLOSeg.nms([det([0, 0, 10, 10], 0.9), det([1, 0, 11, 10], 0.8), det([1, 0, 11, 10], 0.7, 0),
                            det([50, 50, 60, 60], 0.6)], iou: 0.7)
    #expect(kept.map(\.conf) == [0.9, 0.7, 0.6])
}

@Test func decodeReadsChannelMajorLayout() {
    // 2 个 anchor：第 0 个是置信度 0.9 的鸟，第 1 个低于阈值 / anchor 0 is a 0.9 bird, anchor 1 below threshold
    let n = 2
    var raw = [Float](repeating: 0, count: 116 * n)
    raw[0] = 100; raw[n] = 50; raw[2 * n] = 20; raw[3 * n] = 10
    raw[(4 + 14) * n] = 0.9
    raw[(4 + 3) * n + 1] = 0.1
    let dets = YOLOSeg.decode(raw, anchors: n)
    #expect(dets.count == 1 && dets[0].cls == 14 && dets[0].box == [90, 45, 110, 55])
}

@Test func maskIsCroppedToBoxAndThresholdedAtZero() {
    // 只用第 0 个原型（全为正）→ 框内全 true，框外 false / only proto 0 (all positive) is used: true inside the box only
    var d = det([100, 100, 200, 150], 0.9)
    d.coeffs = [1] + [Float](repeating: 0, count: 31)
    var protos = [Float](repeating: -1, count: 32 * 160 * 160)
    for i in 0..<(160 * 160) { protos[i] = 0.5 }
    let m = YOLOSeg.mask(for: d, protos: protos)
    #expect(m[120 * 640 + 150] && !m[99 * 640 + 150] && !m[120 * 640 + 200] && m[149 * 640 + 199])
    #expect(m.filter { $0 }.count == 100 * 50)
}

@Test func letterboxInverseMapping() throws {
    let img = RGBA8Buffer(width: 1280, height: 720, bytes: [UInt8](repeating: 200, count: 1280 * 720 * 4))
    let lb = try #require(img.letterboxed(640))
    #expect(lb.ratio == 0.5 && lb.padX == 0 && lb.padY == 140)
    #expect(lb.image.bytes[0] == 114 && lb.image.bytes[(200 * 640) * 4] == 200)
    let back = lb.unletterbox([50, 190, 250, 390], width: 1280, height: 720)
    #expect(back == [100, 100, 500, 500])
}

@Test func paddedCropMatchesPython() {
    #expect(paddedCropBox([20, 30, 120, 80], width: 1000, height: 1000) == [5, 15, 130, 80])
    #expect(paddedCropBox([0, 0, 100, 100], width: 110, height: 110) == [0, 0, 110, 110])
}

@Test func softmaxAggregationAndTopK() {
    let p = BirdTraceHead.softmax([1000, 1001, 999])
    #expect(abs(p.reduce(0, +) - 1) < 1e-12 && BirdTraceHead.topk(p, 2) == [1, 0])
    // 模型类别 0、1 都映射到鸟种 7，类别 2（-1）丢弃 / model classes 0 and 1 map to species 7; class 2 (-1) is dropped
    let head = BirdTraceHead(classMap: [7, 7, -1])
    let db = head.aggregate([0.5, 0.2, 0.3])
    #expect(db.count == 10964 && abs(db[7] - 0.7) < 1e-12 && abs(db.reduce(0, +) - 0.7) < 1e-12)
}

@Test func bestFallsThroughRegionTiersButNeverToTheWorld() {
    let p = [0.6, 0.3, 0.002, 0.098]
    #expect(BirdTraceHead.best(p, tiers: []) == 0)
    #expect(BirdTraceHead.best([0, 0], tiers: []) == nil)
    // 省州层只有低于 0.3% 的鸟种 → 落到国家层 / the province tier only has a species under 0.3%: falls to the country
    #expect(BirdTraceHead.best(p, tiers: [[2], [2, 3]]) == 3)
    #expect(BirdTraceHead.best(p, tiers: [[1, 3], [0]]) == 1)
    #expect(BirdTraceHead.best(p, tiers: [[2], [2, 99]]) == nil)
}

@Test func regionTiersAreProvinceThenCountry() {
    let fujian = Region(code: "CN-35", en: "Fujian", zh: "福建省", species: [833])
    let checklist = RegionChecklist(countries: [
        Region(code: "CN", en: "China", zh: "中国", species: [7, 833], regions: [fujian]),
        Region(code: "JP", en: "Japan", zh: "日本", species: [9], regions: []),
    ])
    #expect(checklist.tiers(country: "CN", province: "CN-35") == [[833], [7, 833]])
    #expect(checklist.tiers(country: "JP", province: "CN-35") == [[9]])
    #expect(checklist.tiers(country: "CN", province: nil) == [[7, 833]])
    #expect(checklist.tiers(country: nil, province: "CN-35").isEmpty)
}

@Test func multiArrayFloat16Conversion() throws {
    let a = try MLMultiArray(shape: [1, 2, 3], dataType: .float16)
    for i in 0..<6 { a[i] = NSNumber(value: Float(i) / 2) }
    #expect(Inference.floats(a) == [0, 0.5, 1, 1.5, 2, 2.5])
}

@Test func headSharpnessZeroOnFlatCrop() {
    let crop = RGBA8Buffer(width: 100, height: 100, bytes: [UInt8](repeating: 128, count: 100 * 100 * 4))
    // 用二进制可精确表示的坐标，避免 Float 截断 / binary-exact coords avoid Float truncation
    let kp = Keypoints(coords: [0.5, 0.5, 0.625, 0.5, 0.75, 0.5], vis: [0.9, 0.1, 0.9])
    let r = HeadSharpness.compute(crop: crop, keypoints: kp, boxSide: 100, segMask: nil, iso: nil)
    // 眼喙距离 25px × 1.2 = 30 / eye-beak distance 25 px x 1.2 = 30
    #expect(r.score == 0 && r.radius == 30 && r.eye == [50, 50])
    // 眼睛在图外也不能崩溃 / eye outside the crop must not crash
    let out = Keypoints(coords: [3, 3, 3, 3, 3, 3], vis: [0.9, 0.9, 0.1])
    #expect(HeadSharpness.compute(crop: crop, keypoints: out, boxSide: nil, segMask: nil, iso: nil).score == 0)
}

/// 本机已在「设置 › 模型」下载模型时才跑；否则跳过 / Runs only when Settings › Models has downloaded them; skipped otherwise.
@Test(.enabled(if: FileManager.default.fileExists(atPath: installedModelsRepo().appendingPathComponent("models/coreml/birdtrace_fp16.mlpackage").path)))
func birdTraceModelProducesLogits() async throws {
    let store = ModelStore(root: installedModelsRepo().appendingPathComponent("models"))
    let model = try store.load(try await store.compiled("birdtrace", "fp16"))
    let img = RGBA8Buffer(width: 384, height: 384, bytes: [UInt8](repeating: 128, count: 384 * 384 * 4))
    #expect(try Inference.run(model, try img.pixelBuffer())["logits"]?.count == 10480)
}

/// App 安装模型的位置（~/Library/Application Support/Regulus）/ Where the app installs the models.
func installedModelsRepo() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Regulus")
}
