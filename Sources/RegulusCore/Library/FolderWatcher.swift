import CoreServices
import Foundation

/// 用 FSEvents 监听文件夹（含所有子文件夹）里文件和文件夹的新建、删除、移动等变化，用来发现 App 外（如 Finder 里）的改动
/// Watches folders (and everything below them) with FSEvents for files and folders being created, deleted, moved
/// and so on, to notice changes made outside the app (e.g. in Finder).
///
/// 监听的文件夹以下路径中含隐藏项（以「.」开头，如评分临时文件 `.名字.rating-tmp.扩展名`、导入的
/// `.名字.part`）的变化会被忽略，所以 App 自己的这些写入不会触发；非隐藏的改动（包括 App 自己移动照片）照样通知。
/// latency 秒内的多次变化合并成一次；onChange 在私有的后台串行队列上调用。
/// Changes whose path has a hidden component below the watched folder (rating temp files
/// `.name.rating-tmp.ext`, import `.name.part` files) are ignored, so that bookkeeping does not trigger it; other
/// changes, including the app's own moves, still do. Changes within `latency` seconds are coalesced into one call,
/// and onChange runs on a private background serial queue.
///
/// # Examples
/// ```
/// let watcher = FolderWatcher([URL(fileURLWithPath: "/Photos")]) { print("changed") }
/// // 持有 watcher 期间一直监听，释放即停止 / watches while held, stops when released
/// ```
public final class FolderWatcher: @unchecked Sendable {
    // @unchecked：stream 只在 init 和 deinit 里改；回调都在私有串行队列上
    // @unchecked: stream is only changed in init and deinit; callbacks all run on the private serial queue
    private let onChange: @Sendable () -> Void
    private let roots: [String]
    private let queue = DispatchQueue(label: "app.regulus.folder-watcher")
    private var stream: FSEventStreamRef?

    public init(_ folders: [URL], latency: TimeInterval = 2, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        // FSEvents 报告的是真实路径（如 /private/var/...）；resolvingSymlinksInPath 会去掉 /private，所以用 realpath
        // FSEvents reports real paths (e.g. /private/var/...); resolvingSymlinksInPath strips /private, so use realpath
        roots = folders.map { folder in
            realpath(folder.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? folder.path
        }
        // 不 retain self，否则 stream 和 self 互相持有永不释放；deinit 停掉 stream 后不会再有回调
        // self is not retained (that would be a cycle); once deinit stops the stream no callback can arrive
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if changed.contains(where: { FolderWatcher.isRelevant($0, roots: watcher.roots) }) { watcher.onChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        // 在回调队列上停掉，保证没有回调还在用 self / stop on the callback queue so no callback is still using self
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// 变化的路径在监听的文件夹之下是否没有隐藏的一级（以「.」开头）；有就忽略。监听的文件夹本身的事件也忽略：
    /// 里面真有新东西时，那一项自己会有事件。不在任何监听文件夹下的路径按整条路径检查
    /// Whether a changed path has no hidden component (starting with ".") below the watched folder; hidden ones are
    /// ignored. Events on a watched folder itself are ignored too: anything new inside it gets its own event. A path
    /// under no watched folder is checked as a whole.
    static func isRelevant(_ path: String, roots: [String]) -> Bool {
        guard !roots.contains(path) else { return false }
        let root = roots.first { path.hasPrefix($0 + "/") }
        let relative = root.map { String(path.dropFirst($0.count)) } ?? path
        return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
