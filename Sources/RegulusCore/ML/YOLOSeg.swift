import Foundation

/// 一个检测结果（640 信箱坐标系）/ One detection (640 letterbox space).
public struct Detection: Sendable {
    public var box: [Double]  // xyxy
    /// 最高类别分数及其 COCO 类别号 / Best class score and its COCO class index.
    public var conf: Double
    public var cls: Int
    /// 32 个掩码系数 / The 32 mask coefficients.
    public var coeffs: [Float]
}

/// YOLO11-seg 原始输出（导出时 nms=False）的解码，对应 Ultralytics non_max_suppression + process_mask(upsample=True)。
/// Decoding of raw YOLO11-seg outputs (exported with nms=False), mirroring Ultralytics non_max_suppression +
/// process_mask(upsample=True).
public enum YOLOSeg {
    public static let inputSize = 640
    public static let numClasses = 80
    public static let maskDim = 32
    public static let protoSize = 160
    /// COCO 的 "bird" / COCO "bird".
    public static let birdClass = 14

    /// detections：通道优先 [1, 4+80+32, N]（cx,cy,w,h、类别分数、掩码系数），640 输入时 N = 8400。
    /// 每个锚点取最高类别（单标签），分数须 > conf，再做 NMS；结果按置信度降序，最多 maxDet 个。
    /// detections: channel-major [1, 4+80+32, N] (cx,cy,w,h, class scores, mask coeffs), N = 8400 at 640.
    /// Each anchor keeps its best class (single label) if its score > conf, then NMS; desc conf, at most maxDet.
    ///
    /// # Examples
    /// ```
    /// let dets = YOLOSeg.decode(out["detections"]!, anchors: 8400, conf: 0.25, iou: 0.7)
    /// ```
    public static func decode(_ raw: [Float], anchors n: Int, conf: Double = 0.25, iou: Double = 0.7,
                              maxDet: Int = 300) -> [Detection] {
        var cands: [Detection] = []
        for i in 0..<n {
            var best = -Float.infinity, cls = 0
            for c in 0..<numClasses where raw[(4 + c) * n + i] > best {
                best = raw[(4 + c) * n + i]
                cls = c
            }
            guard Double(best) > conf else { continue }
            let cx = Double(raw[i]), cy = Double(raw[n + i]), w = Double(raw[2 * n + i]), h = Double(raw[3 * n + i])
            let coeffs = (0..<maskDim).map { raw[(4 + numClasses + $0) * n + i] }
            cands.append(Detection(box: [cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], conf: Double(best),
                                   cls: cls, coeffs: coeffs))
        }
        return nms(cands, iou: iou, maxDet: maxDet)
    }

    /// 按类别的贪心 NMS：只在同类之间抑制 IoU > iou 的框，效果同 Ultralytics 按 cls*7680 平移后跑 torchvision.nms。
    /// Per-class greedy NMS: suppresses IoU > iou only within a class, the same effect as Ultralytics' cls*7680
    /// offset followed by torchvision.nms.
    ///
    /// # Examples
    /// ```
    /// let kept = YOLOSeg.nms(candidates, iou: 0.7)
    /// ```
    public static func nms(_ dets: [Detection], iou: Double, maxDet: Int = 300) -> [Detection] {
        let sorted = dets.sorted { $0.conf > $1.conf }
        var kept: [Detection] = []
        var suppressed = [Bool](repeating: false, count: sorted.count)
        for i in sorted.indices where !suppressed[i] {
            kept.append(sorted[i])
            if kept.count >= maxDet { break }
            for j in (i + 1)..<sorted.count where !suppressed[j] && sorted[j].cls == sorted[i].cls {
                if boxIoU(sorted[i].box, sorted[j].box) > iou { suppressed[j] = true }
            }
        }
        return kept
    }

    /// 640×640 掩码（行优先）：logits = coeffs·protos(32×160×160) → 双线性放大到 640（align_corners=False）
    /// → > 0；框外（x∉[x1,x2) 或 y∉[y1,y2)）一律为 false。
    /// 640x640 mask (row-major): logits = coeffs·protos (32x160x160) -> bilinear upsample to 640
    /// (align_corners=False) -> > 0; everything outside the box (x∉[x1,x2) or y∉[y1,y2)) is false.
    ///
    /// # Examples
    /// ```
    /// let mask = YOLOSeg.mask(for: det, protos: out["protos"]!)
    /// ```
    public static func mask(for det: Detection, protos: [Float]) -> [Bool] {
        let p = protoSize, plane = p * p
        var logits = [Float](repeating: 0, count: plane)
        protos.withUnsafeBufferPointer { pr in
            for k in 0..<maskDim {
                let c = det.coeffs[k], base = k * plane
                for i in 0..<plane { logits[i] += c * pr[base + i] }
            }
        }
        let s = inputSize, scale = Float(p) / Float(s)
        var out = [Bool](repeating: false, count: s * s)
        let x1 = det.box[0], y1 = det.box[1], x2 = det.box[2], y2 = det.box[3]
        for y in 0..<s where Double(y) >= y1 && Double(y) < y2 {
            let (y0, y1i, fy) = bilinearIndex(Float(y), scale, p)
            for x in 0..<s where Double(x) >= x1 && Double(x) < x2 {
                let (x0, x1i, fx) = bilinearIndex(Float(x), scale, p)
                let top = logits[y0 * p + x0] * (1 - fx) + logits[y0 * p + x1i] * fx
                let bot = logits[y1i * p + x0] * (1 - fx) + logits[y1i * p + x1i] * fx
                out[y * s + x] = top * (1 - fy) + bot * fy > 0
            }
        }
        return out
    }

    /// PyTorch bilinear(align_corners=False) 的源下标对与权重，负坐标夹到 0、越界夹到 n-1。
    /// Source index pair and weight of PyTorch bilinear (align_corners=False); clamped to [0, n-1].
    @inline(__always)
    static func bilinearIndex(_ dst: Float, _ scale: Float, _ n: Int) -> (Int, Int, Float) {
        let src = max(0, (dst + 0.5) * scale - 0.5)
        let i0 = min(Int(src), n - 1)
        let i1 = min(i0 + 1, n - 1)
        return (i0, i1, src - Float(i0))
    }

    /// 两个 xyxy 框的 IoU，并集为 0 时返回 0 / IoU of two xyxy boxes; 0 when the union is empty.
    ///
    /// # Examples
    /// ```
    /// assert(boxIoU([0, 0, 10, 10], [0, 0, 10, 10]) == 1)
    /// ```
    public static func boxIoU(_ a: [Double], _ b: [Double]) -> Double {
        let iw = max(0, min(a[2], b[2]) - max(a[0], b[0])), ih = max(0, min(a[3], b[3]) - max(a[1], b[1]))
        let inter = iw * ih
        let union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
        return union > 0 ? inter / union : 0
    }
}
