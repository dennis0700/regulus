import Foundation
import RegulusCore

/// 分析与鸟名
/// Analysis and species names.
extension LibraryModel {
    func speciesInfo(_ id: Int) -> SpeciesInfo? {
        speciesTable?[id]
    }

    /// 照片标题里的鸟种（标题是名录里的中文鸟名才算）/ The species in the photo's title (only when the title is a
    /// Chinese name from the checklist).
    func speciesInfo(for photo: LibraryPhoto) -> SpeciesInfo? {
        titles[photo.url].flatMap { speciesTable?.info(named: $0) }
    }

    /// 对所选（或当前显示的全部）照片评分、识别鸟种或两者都做，每张分析完就把结果写进照片文件（见 `writeAnalysis`）。
    /// 先评分、删掉废片再识别，可以省掉废片上的识鸟推理
    /// Rate, identify, or both for the selected (or all shown) photos, writing each result into the photo file as soon
    /// as it is ready (see `writeAnalysis`). Rating first and deleting rejects before identifying saves species
    /// inference on the rejects.
    /// region 是识别用的拍摄地区，默认取「设置 › 识别」里的 / region is the shooting region for identification,
    /// by default the one in Settings › Identification.
    func analyzeTargets(_ tasks: AnalysisTasks, region: ShootingRegion = .saved) {
        guard !isAnalyzing else { return }
        let targets = analysisTargets
        guard !targets.isEmpty else { return }
        let missing = analyzer.missingFiles
        guard missing.isEmpty else {
            alertMessage = String(localized: "缺少模型文件，请在「设置 › 模型」中下载：\n\(missing.joined(separator: "\n"))")
            return
        }
        let analyzer = analyzer
        let thresholds = thresholds
        // 每次分析时读名录 / the checklist is read for each analysis
        let regions = (try? RegionChecklist(url: regionsURL))?.tiers(country: region.country,
                                                                     province: region.province) ?? []
        analysis = AnalysisProgress(tasks: tasks, total: targets.count, loadingModels: true)
        analysisTask = Task {
            do {
                try await analyzer.prepare()
            } catch {
                alertMessage = String(localized: "模型加载失败：\(String(describing: error))")
                analysis = nil
                rescanIfPending()
                return
            }
            analysis?.loadingModels = false
            for photo in targets {
                if Task.isCancelled { break }
                do {
                    let record = try await analyzer.analyze(photo.url, thresholds: thresholds, tasks: tasks,
                                                            regions: regions)
                    writeAnalysis(record, to: photo.url)
                } catch {
                    analysis?.failed += 1
                }
                analysis?.done += 1
            }
            if let failed = analysis?.failed, failed > 0 {
                alertMessage = String(localized: "有 \(failed) 张照片无法分析（可能缺少嵌入预览或文件已损坏）。")
            }
            analysis = nil
            analysisTask = nil
            rescanIfPending()
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    /// 把一张照片的分析结果写进文件（后台排队）：AI 星级（1–3）只写给还没评分、没排除的照片；0 星的照片在还没评分、
    /// 没有旗标时标为排除；无鸟不写；识别出的鸟种有名录信息时写标题、描述和关键字
    /// Write one photo's analysis into its file (queued in the background): AI stars (1–3) only go to photos that are
    /// unrated and not rejected; 0-star photos are rejected when unrated and unflagged; no bird is not written; an
    /// identified species with checklist info gets the title, description and keyword.
    private func writeAnalysis(_ record: AnalysisRecord, to url: URL) {
        if let stars = record.rating?.stars, userRatings[url] == nil {
            if stars >= 1, flags[url] != .rejected {
                setUserRating(stars, for: [url])
            } else if stars == 0, flags[url] == nil {
                setFlag(.rejected, for: [url])
            }
        }
        if let id = record.metrics.speciesId, let info = speciesInfo(id) {
            writeSpeciesTags([(url, info)])
        }
    }
}
