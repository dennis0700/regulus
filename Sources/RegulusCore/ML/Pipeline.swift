import CoreML
import Foundation

/// 端到端单图结果 / End-to-end result for one image.
public struct PipelineResult: Sendable {
    public var birdFound = false
    /// 置信度最高的那只鸟的 YOLO 置信度 / YOLO confidence of the most confident bird.
    public var birdConf: Double?
    /// 鸟种库类别号（BirdTrace 概率按 class_map 累加后的 top-1，累加概率为 0 时不填）及其概率
    /// Species-DB id (top-1 after summing BirdTrace probabilities through the class map; unset if that sum is 0)
    /// and its probability.
    public var speciesId: Int?
    public var speciesIdProb: Double?
    public var keypoints: Keypoints?
    /// 头部锐度，见 `HeadSharpness.compute` / Head sharpness, see `HeadSharpness.compute`.
    public var headSharpness: Double?
    /// 飞版模型的 "prob" 输出 / The flight model's "prob" output.
    public var flightProb: Double?
    /// TOPIQ 模型的 "mos" 输出 / The TOPIQ model's "mos" output.
    public var topiq: Double?
}

/// 读图（RAW 用嵌入预览）→ YOLO 找鸟 → 外扩裁剪 → BirdTrace 识别 和 / 或 关键点 + 头部锐度、飞版、TOPIQ。
/// Load (embedded preview for RAW) -> YOLO bird detection -> padded crop -> BirdTrace and/or keypoints + head
/// sharpness, flight, TOPIQ.
public final class Pipeline {
    let yolo: MLModel, birdtrace: MLModel, keypoint: MLModel, flight: MLModel, topiq: MLModel
    let head: BirdTraceHead

    /// 模型键 → 包名（实际文件为 models/coreml/<包名>_fp16.mlpackage）
    /// Model key -> package name (the file is models/coreml/<name>_fp16.mlpackage).
    public static let packageNames = ["yolo": "yolo11l-seg", "birdtrace": "birdtrace", "keypoint": "keypoint",
                                      "flight": "flight", "topiq": "topiq"]

    /// 编译（有缓存则复用）并加载 repo/models 下的五个 fp16 模型和 birdtrace_class_map.json；缺文件时抛错。
    /// Compile (reusing the cache) and load the five fp16 models plus birdtrace_class_map.json under repo/models;
    /// throws if any is missing.
    ///
    /// # Examples
    /// ```
    /// let p = try await Pipeline(repo: URL(fileURLWithPath: "."))
    /// ```
    public init(repo: URL) async throws {
        let store = ModelStore(root: repo.appendingPathComponent("models"))
        var loaded: [String: MLModel] = [:]
        for (key, pkg) in Self.packageNames {
            loaded[key] = try store.load(try await store.compiled(pkg, "fp16"))
        }
        guard let y = loaded["yolo"], let b = loaded["birdtrace"], let k = loaded["keypoint"],
              let f = loaded["flight"], let t = loaded["topiq"] else { throw RegulusError.model("model load") }
        (yolo, birdtrace, keypoint, flight, topiq) = (y, b, k, f, t)
        head = try BirdTraceHead(classMap: repo.appendingPathComponent("models/birdtrace_class_map.json"))
    }

    /// 处理一张图，只分析置信度最高的那只鸟（YOLO conf 0.25、IoU 0.7）；无鸟时 YOLO 之后即停止（同 SuperPicky）。
    /// tasks 决定跑哪些模型：只评分时跳过 BirdTrace，只识别时跳过关键点、锐度、飞版和美学，跳过的字段为 nil。
    /// iso 用于锐度的 ISO 折算，nil 表示不折算。regions 是识别的地区候选层（见 `BirdTraceHead.best`），空为不筛选。
    /// Process one image, analysing only the most confident bird (YOLO conf 0.25, IoU 0.7); stops after YOLO when
    /// there is none (as SuperPicky). tasks picks the models: rating only skips BirdTrace, identifying only skips
    /// keypoints, sharpness, flight and aesthetics; skipped fields stay nil. iso drives the sharpness ISO discount
    /// (nil = none). regions are the identification's regional candidate tiers (see `BirdTraceHead.best`); empty
    /// means no filtering.
    ///
    /// # Examples
    /// ```
    /// let r = try pipeline.process(URL(fileURLWithPath: "samples/jpeg/perched_chiffchaff.jpg"))
    /// let rateOnly = try pipeline.process(url, tasks: .rate)
    /// let inFujian = try pipeline.process(url, regions: checklist.tiers(country: "CN", province: "CN-35"))
    /// ```
    public func process(_ url: URL, iso: Double? = nil, tasks: AnalysisTasks = .all,
                        regions: [Set<Int>] = []) throws -> PipelineResult {
        let img = try RGBA8Buffer.loadForAnalysis(url)
        var r = PipelineResult()
        guard let lb = img.letterboxed(YOLOSeg.inputSize) else { throw RegulusError.imageIO("letterbox failed") }
        let out = try Inference.run(yolo, try lb.image.pixelBuffer())
        let dets = YOLOSeg.decode(out["detections"] ?? [], anchors: 8400)
        if let bird = dets.filter({ $0.cls == YOLOSeg.birdClass }).max(by: { $0.conf < $1.conf }) {
            try analyzeBird(bird, protos: out["protos"] ?? [], img: img, lb: lb, iso: iso, tasks: tasks,
                            regions: regions, into: &r)
        }
        return r
    }

    private func analyzeBird(_ bird: Detection, protos: [Float], img: RGBA8Buffer, lb: Letterbox, iso: Double?,
                             tasks: AnalysisTasks, regions: [Set<Int>], into r: inout PipelineResult) throws {
        let box = lb.unletterbox(bird.box, width: img.width, height: img.height)
        r.birdFound = true
        r.birdConf = bird.conf
        let c = paddedCropBox(box, width: img.width, height: img.height)
        let crop = img.cropped(x: c[0], y: c[1], w: c[2], h: c[3])
        if tasks.contains(.identify) {
            try identify(box: box, crop: c, img: img, regions: regions, into: &r)
        }
        if tasks.contains(.rate) {
            try rate(bird, box: box, crop: crop, cropBox: c, protos: protos, lb: lb, iso: iso, into: &r)
        }
    }

    /// BirdTrace 识鸟种：以鸟框中心取边长 = 外扩裁剪长边（不超过图像短边）的正方形，平移到图内，Lanczos 缩到 384；
    /// 按 regions 逐层筛选。
    /// BirdTrace species ID: a square centred on the box, side = long side of the padded crop (capped at the image's
    /// short side), shifted inside the image, Lanczos-resized to 384; filtered tier by tier through regions.
    private func identify(box: [Double], crop c: [Int], img: RGBA8Buffer, regions: [Set<Int>],
                          into r: inout PipelineResult) throws {
        let side = min(min(img.width, img.height), Int(Double(max(c[2], c[3]))))
        let cx = Int((box[0] + box[2]) / 2), cy = Int((box[1] + box[3]) / 2)
        let sx = max(0, min(img.width - side, cx - side / 2)), sy = max(0, min(img.height - side, cy - side / 2))
        guard let inp = img.cropped(x: sx, y: sy, w: side, h: side).resized(width: 384, height: 384, quality: .high)
        else { return }
        let probs = BirdTraceHead.softmax(try Inference.run(birdtrace, try inp.pixelBuffer())["logits"] ?? [])
        let db = head.aggregate(probs)
        if let top = BirdTraceHead.best(db, tiers: regions) {
            r.speciesId = top
            r.speciesIdProb = db[top]
        }
    }

    /// 评分要的指标：关键点 416（双线性）+ 掩码内头部锐度、飞版 384（双线性）、TOPIQ 384（Lanczos），都基于外扩裁剪图。
    /// Rating metrics on the padded crop: keypoints at 416 (bilinear) + masked head sharpness, flight at 384
    /// (bilinear), TOPIQ at 384 (Lanczos).
    private func rate(_ bird: Detection, box: [Double], crop: RGBA8Buffer, cropBox c: [Int], protos: [Float],
                      lb: Letterbox, iso: Double?, into r: inout PipelineResult) throws {
        // 裁剪图像素 → 原图坐标 → 信箱坐标，最近邻取 640 掩码 / crop pixel -> original -> letterbox, nearest lookup
        let m = YOLOSeg.mask(for: bird, protos: protos)
        var segCrop = [Bool](repeating: false, count: crop.width * crop.height)
        for y in 0..<crop.height {
            let ly = Int((Double(y + c[1]) * lb.ratio).rounded()) + lb.padY
            for x in 0..<crop.width {
                let lx = Int((Double(x + c[0]) * lb.ratio).rounded()) + lb.padX
                if lx >= 0, ly >= 0, lx < YOLOSeg.inputSize, ly < YOLOSeg.inputSize {
                    segCrop[y * crop.width + x] = m[ly * YOLOSeg.inputSize + lx]
                }
            }
        }
        if let inp = crop.resized(width: 416, height: 416, quality: .medium) {
            let o = try Inference.run(keypoint, try inp.pixelBuffer())
            let kp = Keypoints(coords: o["coords"] ?? [], vis: o["vis"] ?? [])
            let hs = HeadSharpness.compute(crop: crop, keypoints: kp, boxSide: Int(max(box[2] - box[0], box[3] - box[1])),
                                           segMask: segCrop, iso: iso)
            r.keypoints = kp
            r.headSharpness = hs.score
        }
        if let inp = crop.resized(width: 384, height: 384, quality: .medium) {
            r.flightProb = Double(try Inference.run(flight, try inp.pixelBuffer())["prob"]?.first ?? 0)
        }
        if let inp = crop.resized(width: 384, height: 384, quality: .high) {
            r.topiq = Double(try Inference.run(topiq, try inp.pixelBuffer())["mos"]?.first ?? 0)
        }
    }
}
