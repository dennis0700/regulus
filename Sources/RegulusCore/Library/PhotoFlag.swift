import Foundation

/// 照片的旗标，写在照片文件里（见 `RatingFile`）：旗标为 `xmp:Label` = "Select"（Adobe Bridge 的约定），
/// 排除为 `xmp:Rating` = -1（Bridge、darktable 的约定，排除后不再有星级）
/// A photo's flag, stored in the photo file (see `RatingFile`): picked is `xmp:Label` = "Select" (Adobe Bridge's
/// convention), rejected is `xmp:Rating` = -1 (the Bridge / darktable convention, so a rejected photo has no stars).
public enum PhotoFlag: String, Sendable, CaseIterable {
    /// 旗标（保留）/ Picked (keep).
    case picked
    /// 排除（只是标记，不会删除文件）/ Rejected (a mark only; no file is deleted).
    case rejected

    /// 表示旗标的 `xmp:Label` 值 / The `xmp:Label` value meaning picked.
    static let pickedLabel = "Select"
}
