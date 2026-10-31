/// RegulusCore 错误 / RegulusCore errors.
public enum RegulusError: Error, CustomStringConvertible {
    case metadata(String)
    case imageIO(String)
    case model(String)
    case update(String)

    public var description: String {
        switch self {
        case .metadata(let m): "Metadata: \(m)"
        case .imageIO(let m): "ImageIO: \(m)"
        case .model(let m): "CoreML: \(m)"
        case .update(let m): "Update: \(m)"
        }
    }
}
