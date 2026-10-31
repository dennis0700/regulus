import Foundation

/// 一个文件的移动结果 / Result of moving one file.
public struct MoveResult: Sendable, Equatable {
    public let source: URL
    /// 移到了哪里；失败或本来就在目标文件夹里时为 nil / Where it went; nil on failure or when already in the folder.
    public let destination: URL?
    /// 失败原因；成功或跳过时为 nil / Why it failed; nil when moved or skipped.
    public let error: String?
}

/// 把照片移到另一个文件夹 / Moves photos into another folder.
public enum PhotoMover {
    /// 逐个移动，结果与输入一一对应；目标里有同名文件时依次试 `名字_1.扩展名`、`名字_2.扩展名`…，从不覆盖；
    /// 本来就在目标文件夹里的跳过。同一块盘上只是改名；跨盘时 FileManager 先复制再删除原文件
    /// Move one by one, one result per input; a taken name becomes `name_1.ext`, `name_2.ext`, ... so nothing is ever
    /// overwritten; files already in the folder are skipped. On the same volume it is a rename; across volumes
    /// FileManager copies then deletes.
    ///
    /// # Examples
    /// ```
    /// let results = PhotoMover.move([URL(fileURLWithPath: "/Photos/Raw/DSC00001.ARW")],
    ///                               to: URL(fileURLWithPath: "/Photos/Selected"))
    /// ```
    public static func move(_ files: [URL], to folder: URL) -> [MoveResult] {
        let folder = folder.standardizedFileURL
        return files.map { file in
            let file = file.standardizedFileURL
            guard file.deletingLastPathComponent().path != folder.path else {
                return MoveResult(source: file, destination: nil, error: nil)
            }
            var target = folder.appendingPathComponent(file.lastPathComponent)
            var suffix = 0
            while FileManager.default.fileExists(atPath: target.path) {
                suffix += 1
                target = folder.appendingPathComponent(PhotoImporter.numbered(file.lastPathComponent, suffix))
            }
            do {
                try FileManager.default.moveItem(at: file, to: target)
                return MoveResult(source: file, destination: target, error: nil)
            } catch {
                return MoveResult(source: file, destination: nil, error: error.localizedDescription)
            }
        }
    }
}
