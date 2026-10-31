import Foundation
import RegulusCore

/// 写进照片文件的评分和鸟种信息
/// Ratings and species info written into the photo files.
extension LibraryModel {
    func userRating(for photo: LibraryPhoto) -> Int? {
        userRatings[photo.url]
    }

    /// 把评分写进照片文件（不给 urls 时用所选照片，写不了的视频、RAF 跳过）；nil（按 0）清除。评分会覆盖排除（两者都在 `xmp:Rating` 里）。
    /// 界面立即更新，写入在后台排队进行；失败的恢复原值（期间重新加载过照片库则不恢复）
    /// Write the rating into the photo files (the selection without urls; videos and RAF are skipped); nil (the 0 key) clears it. A rating
    /// replaces a reject (both live in `xmp:Rating`). The UI updates at once; writes are queued in the background and
    /// failures are rolled back (unless the library was reloaded meanwhile).
    func setUserRating(_ stars: Int?, for urls: [URL]? = nil) {
        let targets = (urls ?? visiblePhotos.map(\.url).filter { selection.contains($0) })
            .filter(RatingFile.canWrite)
        guard !targets.isEmpty else { return }
        let previous = targets.map { userRatings[$0] }
        let previousFlags = targets.map { flags[$0] }
        for url in targets {
            userRatings[url] = stars
            pendingRatings[url] = stars ?? 0
            if flags[url] == .rejected { flags[url] = nil }
        }
        let startGeneration = generation
        let earlier = fileWrites
        fileWrites = Task {
            await earlier?.value
            let failed = await Task.detached(priority: .userInitiated) {
                targets.indices.filter { index in
                    (try? RatingFile.write(stars ?? 0, to: targets[index])) == nil
                }
            }.value
            // 这批写完了（失败的下面回滚），不再需要覆盖扫描结果；之后又改过的仍留着等下一批
            // this batch is done (failures are rolled back below), so stop overriding scans; values changed again
            // since stay pending for the next batch
            for url in targets where pendingRatings[url] == stars ?? 0 { pendingRatings[url] = nil }
            guard !failed.isEmpty, generation == startGeneration else { return }
            // 只回滚仍是本次设置的值，之后又改过的不动 / roll back only values still set by this call
            for index in failed where userRatings[targets[index]] == stars {
                userRatings[targets[index]] = previous[index]
                flags[targets[index]] = previousFlags[index]
            }
            let names = Self.nameList(failed.map { targets[$0].lastPathComponent })
            alertMessage = String(localized: "有 \(failed.count) 张照片的评分没能写入：\(names)")
        }
    }

    /// 这些照片里标题是已知鸟种的 / Of these photos, the ones whose title is a known species.
    func speciesTagTargets(_ urls: [URL]) -> [(url: URL, info: SpeciesInfo)] {
        urls.compactMap { url in
            titles[url].flatMap { speciesTable?.info(named: $0) }.map { (url, $0) }
        }
    }

    /// 按名录重写这些照片的鸟种信息（右键菜单）；标题不是已知鸟种的跳过
    /// Rewrite the species info of these photos from the checklist (context menu); photos whose title is not a
    /// known species are skipped.
    func writeSpeciesTags(_ urls: [URL]) {
        writeSpeciesTags(speciesTagTargets(urls))
    }

    /// 把鸟种信息（标题、描述、关键字）写进照片文件，在后台与评分写入共用一个队列；识别后自动调用，写成功的更新标题
    /// Write species info (title, description, keyword) into the photo files, queued in the background with rating
    /// writes; called after identifying, and the titles of successful writes are updated.
    func writeSpeciesTags(_ targets: [(url: URL, info: SpeciesInfo)]) {
        guard !targets.isEmpty else { return }
        let startGeneration = generation
        let earlier = fileWrites
        fileWrites = Task {
            await earlier?.value
            let failed = await Task.detached(priority: .utility) {
                targets.filter { (try? SpeciesTagFile.write($0.info, to: $0.url)) == nil }.map(\.url)
            }.value
            if generation == startGeneration {
                for target in targets where !failed.contains(target.url) { titles[target.url] = target.info.zh }
            }
            guard !failed.isEmpty else { return }
            let names = Self.nameList(failed.map(\.lastPathComponent))
            alertMessage = String(localized: "有 \(failed.count) 张照片的鸟种信息没能写入：\(names)")
        }
    }
}
