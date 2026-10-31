import CoreML
import CoreVideo
import Foundation

/// models/coreml/*.mlpackage 的定位、编译缓存与加载 / Locate, compile-cache and load models/coreml/*.mlpackage.
public struct ModelStore: Sendable {
    public let root: URL

    /// root = 模型目录（下有 coreml/、compiled/），App 中为 ~/Library/Application Support/Regulus/models
    /// root = the models directory (holding coreml/ and compiled/); in the app,
    /// ~/Library/Application Support/Regulus/models.
    ///
    /// # Examples
    /// ```
    /// let store = ModelStore(root: URL(fileURLWithPath: "models"))
    /// ```
    public init(root: URL) {
        self.root = root
    }

    /// mlpackage 路径 / mlpackage path: root/coreml/<name>_<precision>.mlpackage.
    ///
    /// # Examples
    /// ```
    /// let pkg = store.package("birdtrace", "fp16")   // .../coreml/birdtrace_fp16.mlpackage
    /// ```
    public func package(_ name: String, _ precision: String) -> URL {
        root.appendingPathComponent("coreml/\(name)_\(precision).mlpackage")
    }

    /// 编译并缓存到 root/compiled/<name>_<precision>.mlmodelc；缓存的修改时间不早于包内 Manifest.json 时直接复用，
    /// 否则（或读不到时间）重编并替换。mlpackage 不存在时抛错。
    /// Compile and cache as root/compiled/<name>_<precision>.mlmodelc; reused when it is not older than the package's
    /// Manifest.json, otherwise (or if either date is unreadable) recompiled and replaced. Throws if the package is
    /// missing.
    ///
    /// # Examples
    /// ```
    /// let compiled = try await store.compiled("yolo11l-seg", "fp16")
    /// ```
    public func compiled(_ name: String, _ precision: String) async throws -> URL {
        let pkg = package(name, precision)
        guard FileManager.default.fileExists(atPath: pkg.path) else {
            throw RegulusError.model("missing \(pkg.path)")
        }
        let dest = root.appendingPathComponent("compiled/\(name)_\(precision).mlmodelc")
        let fm = FileManager.default
        if let d = try? fm.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date,
           let p = try? fm.attributesOfItem(atPath: pkg.appendingPathComponent("Manifest.json").path)[.modificationDate]
            as? Date, d >= p {
            return dest
        }
        let tmp = try await MLModel.compileModel(at: pkg)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    /// 用默认配置加载已编译模型（计算单元 .all）/ Load a compiled model with the default config (.all compute units).
    ///
    /// # Examples
    /// ```
    /// let model = try store.load(compiledURL)
    /// ```
    public func load(_ compiled: URL) throws -> MLModel {
        try MLModel(contentsOf: compiled)
    }
}

/// 单输入图像模型的推理封装 / Inference wrapper for single-image-input models.
public enum Inference {
    /// 以 "image" 输入跑一次，返回各 MLMultiArray 输出展平后的 Float 数组（非数组输出被忽略）。
    /// Run once with the "image" input; every MLMultiArray output flattened to [Float] (other outputs skipped).
    ///
    /// # Examples
    /// ```
    /// let out = try Inference.run(model, pixelBuffer)
    /// let logits = out["logits"]!
    /// ```
    public static func run(_ model: MLModel, _ image: CVPixelBuffer) throws -> [String: [Float]] {
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: image)])
        let out = try model.prediction(from: input)
        var result: [String: [Float]] = [:]
        for name in out.featureNames {
            if let arr = out.featureValue(for: name)?.multiArrayValue { result[name] = floats(arr) }
        }
        return result
    }

    /// MLMultiArray（Float16/Float32/Double，任意步长）→ 行优先 [Float]；其他数据类型按 Float32 读取。
    /// MLMultiArray (Float16/Float32/Double, any strides) -> row-major [Float]; other data types are read as Float32.
    ///
    /// # Examples
    /// ```
    /// let xs = Inference.floats(array)
    /// ```
    public static func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        // 连续存储快速路径（长度为 1 的维度不看步长）/ contiguous fast path (strides of size-1 dims don't matter)
        var expected = 1, contiguous = true
        for d in stride(from: shape.count - 1, through: 0, by: -1) {
            if shape[d] > 1 && strides[d] != expected { contiguous = false }
            expected *= shape[d]
        }
        if contiguous {
            switch a.dataType {
            case .float16:
                let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
                for i in 0..<count { out[i] = Float(p[i]) }
                return out
            case .float32:
                let p = a.dataPointer.assumingMemoryBound(to: Float.self)
                out.withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: p, count: count) }
                return out
            default: break
            }
        }
        var idx = [Int](repeating: 0, count: shape.count)
        let get: (Int) -> Float
        switch a.dataType {
        case .float16:
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            get = { Float(p[$0]) }
        case .double:
            let p = a.dataPointer.assumingMemoryBound(to: Double.self)
            get = { Float(p[$0]) }
        default:
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            get = { p[$0] }
        }
        for i in 0..<count {
            var off = 0
            for d in 0..<shape.count { off += idx[d] * strides[d] }
            out[i] = get(off)
            var d = shape.count - 1
            while d >= 0 {
                idx[d] += 1
                if idx[d] < shape[d] { break }
                idx[d] = 0
                d -= 1
            }
        }
        return out
    }
}
