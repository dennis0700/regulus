import Foundation
import ImageCaptureCore
import Observation

// 通过 ImageCaptureCore（PTP）从 USB 直连的相机导入，与系统「图像捕捉」App 用的是同一套框架
// Import from USB-connected cameras over PTP via ImageCaptureCore, the framework behind Image Capture.

public enum CameraError: Error, CustomStringConvertible {
    case disconnected
    case downloadFailed(String)
    case deleteFailed(String)
    /// 照片在相机里设了保护，或相机不允许删除 / Protected in the camera, or the camera does not allow deleting.
    case protected(String)

    public var description: String {
        switch self {
        case .disconnected: "相机已断开 / camera disconnected"
        case let .downloadFailed(name): "无法从相机下载 \(name) / download from camera failed"
        case let .deleteFailed(name): "无法删除相机里的 \(name) / delete in camera failed"
        case let .protected(name): "\(name) 受保护或相机不允许删除，已保留 / protected or not deletable, kept"
        }
    }
}

/// 相机里的一个照片文件 / A photo file inside a PTP camera.
///
/// `ICCameraFile` 没有标注 Sendable；这里只在导入任务里串行使用它（一次一个下载请求），
/// 并且只调用 ImageCaptureCore 的异步请求接口，所以用 @unchecked Sendable。
/// `ICCameraFile` is not annotated Sendable; it is only used serially by the import task (one download
/// at a time) through ImageCaptureCore's asynchronous request API, hence @unchecked Sendable.
public struct CameraFile: ImportItem, @unchecked Sendable {
    let file: ICCameraFile
    public let name: String
    public let size: Int64
    public let captureDate: DateComponents
    let modified: Date?

    init(_ file: ICCameraFile) {
        self.file = file
        name = file.name ?? "untitled"
        size = Int64(file.fileSize)
        // EXIF 时间没有时区，系统按本机时区解释，所以用本机日历换回年月日即为相机本地日期
        // EXIF times carry no zone and are read in the local zone, so the local calendar gives the camera's date back.
        let date = file.exifCreationDate ?? file.creationDate ?? file.fileCreationDate
        captureDate = MediaScanner.fallbackDate(date)
        modified = file.exifCreationDate ?? file.modificationDate ?? file.fileModificationDate
    }

    /// 相机上的文件不能原地计算哈希 / A file inside the camera cannot be hashed in place.
    public func contentHash() async throws -> String? { nil }

    /// 下载到 `part` / Download to `part`.
    public func stage(to part: URL) async throws {
        let folder = part.deletingLastPathComponent()
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: folder,
            .saveAsFilename: part.lastPathComponent,
            .overwrite: true,
        ]
        let saved: String = try await withCheckedThrowingContinuation { continuation in
            let progress = file.requestDownload(options: options) { filename, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let filename {
                    continuation.resume(returning: filename)
                } else {
                    continuation.resume(throwing: CameraError.downloadFailed(name))
                }
            }
            if progress == nil { continuation.resume(throwing: CameraError.downloadFailed(name)) }
        }
        // 回调给的可能是文件名，也可能是完整路径；没存成 part 的名字就挪过去
        // The callback may hand back a name or a full path; move it to `part` if it was saved under another name.
        let savedURL = saved.hasPrefix("/") ? URL(fileURLWithPath: saved) : folder.appendingPathComponent(saved)
        if savedURL.standardizedFileURL != part.standardizedFileURL {
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: savedURL, to: part)
        }
    }

    /// 一次只下载一个，见类型说明 / One download at a time, see the type's notes.
    public var importsConcurrently: Bool { false }

    public func preservedDates() -> [FileAttributeKey: Date] {
        guard let modified else { return [:] }
        return [.creationDate: modified, .modificationDate: modified]
    }

    /// 删除相机里的这个文件。文件或相机被锁定、相机不支持单张删除时抛 `CameraError.protected`，
    /// 相机报告删除失败时抛 `CameraError.deleteFailed`，两种情况文件都保留
    /// Delete this file in the camera. Throws `CameraError.protected` when the file or camera is locked or the camera
    /// cannot delete single files, and `CameraError.deleteFailed` when the camera reports a failure; the file is kept.
    public func deleteSource() async throws {
        guard let device = file.device, !file.isLocked, !device.isLocked,
              device.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
        else { throw CameraError.protected(name) }
        let name = name
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let progress = device.requestDeleteFiles([file], deleteFailed: { _ in }) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if !(result[.failed] ?? []).isEmpty {
                    continuation.resume(throwing: CameraError.deleteFailed(name))
                } else {
                    continuation.resume()
                }
            }
            if progress == nil { continuation.resume(throwing: CameraError.deleteFailed(name)) }
        }
    }
}

/// 列出通过 USB 连接的 PTP 相机 / Lists PTP cameras connected over USB.
///
/// 已经挂载成磁盘的设备（读卡器、大容量存储模式）不在这里列出，它们走 `MediaScanner.cameraCards()`，
/// 那条路径更快，并且能逐字节校验。
/// Devices that are mounted as disks (card readers, mass-storage mode) are left out: they go through
/// `MediaScanner.cameraCards()`, which is faster and verifies byte for byte.
///
/// # Examples
/// ```
/// let browser = CameraBrowser()   // 在主线程创建并持有 / create and keep on the main actor
/// browser.cameras                 // 随插拔更新 / updates as cameras come and go
/// ```
@MainActor @Observable
public final class CameraBrowser: NSObject, ICDeviceBrowserDelegate {
    public private(set) var cameras: [ICCameraDevice] = []
    @ObservationIgnored let browser = ICDeviceBrowser()

    override public init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
    }

    // ICDeviceBrowser 的 delegate 是 assign（不持有）；释放前必须停掉并清空，否则设备插拔时会回调已释放的对象而崩溃
    // ICDeviceBrowser's delegate is assign (not retained): stop and clear it before going away, or a later
    // device add/remove calls into freed memory and crashes.
    isolated deinit {
        browser.stop()
        browser.delegate = nil
    }

    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        nonisolated(unsafe) let device = device
        Task { @MainActor in
            // 存储卡也会被 ImageCaptureCore 列成"相机"；mountPoint 在设备刚出现时可能还是空的，所以还要按传输类型排除
            // ImageCaptureCore lists memory cards as "cameras" too; mountPoint can still be nil when the device first
            // appears, so they are also excluded by transport type.
            guard let camera = device as? ICCameraDevice,
                  camera.transportType != ICDeviceTransport.transportTypeMassStorage.rawValue, camera.mountPoint == nil,
                  !cameras.contains(camera) else { return }
            cameras.append(camera)
        }
    }

    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        nonisolated(unsafe) let device = device
        Task { @MainActor in cameras.removeAll { $0 == device } }
    }
}

/// 与一台相机的会话：打开会话、读取文件列表、结束后关闭
/// A session with one camera: open it, read the file catalog, close it when done.
@MainActor
public final class CameraSession: NSObject, ICCameraDeviceDelegate {
    public let camera: ICCameraDevice
    private var catalog: CheckedContinuation<[CameraFile], Error>?

    public init(camera: ICCameraDevice) {
        self.camera = camera
        super.init()
    }

    /// 打开会话并等到相机列完全部文件，返回可导入的照片和视频（按文件名排序）；相机断开时抛 `CameraError.disconnected`
    /// Open the session, wait for the full catalog, and return importable photos and videos sorted by name;
    /// throws `CameraError.disconnected` if the camera goes away.
    ///
    /// # Examples
    /// ```
    /// let session = CameraSession(camera: camera)
    /// let files = try await session.open()
    /// defer { session.close() }
    /// ```
    public func open() async throws -> [CameraFile] {
        camera.delegate = self
        // 支持 HEIF 的设备默认只给转码后的 JPG，这里要原片 / HEIF devices hand out converted JPGs by default; ask for originals
        if camera.capabilities.contains(ICDeviceCapability.cameraDeviceSupportsHEIF.rawValue) {
            camera.mediaPresentation = .originalAssets
        }
        return try await withCheckedThrowingContinuation { continuation in
            catalog = continuation
            // 会话已开且目录已完整就直接返回，否则等 deviceDidBecomeReady
            // Return at once if the session is open with a complete catalog; otherwise wait for deviceDidBecomeReady.
            if camera.hasOpenSession, camera.contentCatalogPercentCompleted >= 100 {
                finishCatalog(nil)
            } else if !camera.hasOpenSession {
                camera.requestOpenSession()
            }
        }
    }

    /// 关闭会话并解除 delegate / Close the session and detach the delegate.
    ///
    /// # Examples
    /// ```
    /// session.close()
    /// ```
    public func close() {
        if camera.hasOpenSession { camera.requestCloseSession() }
        camera.delegate = nil
    }

    private func finishCatalog(_ error: Error?) {
        guard let continuation = catalog else { return }
        catalog = nil
        if let error {
            continuation.resume(throwing: error)
            return
        }
        let files = Self.allFiles(camera.mediaFiles ?? [])
            .filter { MediaScanner.importExtensions.contains(URL(fileURLWithPath: $0.name ?? "").pathExtension.lowercased()) }
            .map(CameraFile.init)
            .sorted { $0.name < $1.name }
        continuation.resume(returning: files)
    }

    /// 展开挂在主文件下的配对 RAW 和附属文件（去重），避免 RAW+JPEG 只导入了 JPEG
    /// Include paired RAWs and sidecars hanging off a primary file (deduplicated), so RAW+JPEG does not import
    /// only the JPEG.
    static func allFiles(_ items: [ICCameraItem]) -> [ICCameraFile] {
        var seen = Set<ObjectIdentifier>()
        var result: [ICCameraFile] = []
        for case let file as ICCameraFile in items {
            let related = [file.pairedRawImage].compactMap { $0 } + (file.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }
            for candidate in [file] + related where seen.insert(ObjectIdentifier(candidate)).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    // MARK: ICDeviceDelegate

    // 打开成功时什么也不做，目录要等 deviceDidBecomeReady 才完整
    // Success does nothing here: the catalog is complete only at deviceDidBecomeReady.
    nonisolated public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in if let error { finishCatalog(error) } }
    }

    nonisolated public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in finishCatalog(CameraError.disconnected) }
    }

    nonisolated public func didRemove(_ device: ICDevice) {
        Task { @MainActor in finishCatalog(CameraError.disconnected) }
    }

    // MARK: ICCameraDeviceDelegate

    nonisolated public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in finishCatalog(nil) }
    }

    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                                         for item: ICCameraItem, error: (any Error)?) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                                         for item: ICCameraItem, error: (any Error)?) {}
    nonisolated public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
