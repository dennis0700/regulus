import Foundation
import RegulusCore

/// 旗标
/// Flags.
extension LibraryModel {
    func flag(for photo: LibraryPhoto) -> PhotoFlag? {
        flags[photo.url]
    }

    /// 侧边栏各旗标的数量 / Per-flag counts for the sidebar.
    var flagCounts: [PhotoFlag: Int] {
        var counts: [PhotoFlag: Int] = [:]
        for photo in snapshot?.photos ?? [] {
            if let flag = flag(for: photo) { counts[flag, default: 0] += 1 }
        }
        return counts
    }

    /// 给照片设旗标（nil 为无旗标）并写进照片文件（见 `PhotoFlag`），不给 urls 时用所选照片，写不了的视频、RAF 跳过；排除会清掉星级。
    /// 界面立即更新，写入在后台排队进行；失败的恢复原值（期间重新加载过照片库则不恢复）
    /// Flag photos (nil unflags them) and write it into the photo files (see `PhotoFlag`); without urls, the
    /// selection; videos and RAF are skipped. Rejecting clears the stars. The UI updates at once; writes are queued in the background and
    /// failures are rolled back (unless the library was reloaded meanwhile).
    func setFlag(_ flag: PhotoFlag?, for urls: [URL]? = nil) {
        let targets = (urls ?? Array(selection)).filter(RatingFile.canWrite)
        guard !targets.isEmpty else { return }
        let previous = targets.map { flags[$0] }
        let previousStars = targets.map { userRatings[$0] }
        for url in targets {
            flags[url] = flag
            pendingFlags.updateValue(flag, forKey: url)
            if flag == .rejected { userRatings[url] = nil }
        }
        let startGeneration = generation
        let earlier = fileWrites
        fileWrites = Task {
            await earlier?.value
            let failed = await Task.detached(priority: .userInitiated) {
                targets.indices.filter { (try? RatingFile.write(flag, to: targets[$0])) == nil }
            }.value
            // 这批写完了，不再需要覆盖扫描结果；之后又改过的仍留着等下一批
            // this batch is done, so stop overriding scans; values changed again since stay pending for the next batch
            for url in targets where pendingFlags[url] == .some(flag) { pendingFlags[url] = nil }
            guard !failed.isEmpty, generation == startGeneration else { return }
            // 只回滚仍是本次设置的值 / roll back only values still set by this call
            for index in failed where flags[targets[index]] == flag {
                flags[targets[index]] = previous[index]
                userRatings[targets[index]] = previousStars[index]
            }
            let names = Self.nameList(failed.map { targets[$0].lastPathComponent })
            alertMessage = String(localized: "有 \(failed.count) 张照片的旗标没能写入：\(names)")
        }
    }

    /// 照片库里标记为「排除」的照片 / Library photos flagged as rejected.
    var rejectedPhotos: [LibraryPhoto] {
        snapshot?.photos.filter { flag(for: $0) == .rejected } ?? []
    }
}
