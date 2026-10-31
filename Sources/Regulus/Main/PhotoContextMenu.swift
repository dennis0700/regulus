import AppKit
import RegulusCore
import SwiftUI

/// 照片的右键菜单，网格、预览大图和胶片栏共用；在已选中的照片上右键时处理整个选择
/// A photo's context menu, shared by the grid, the preview and the filmstrip; on a selected photo it acts on the
/// whole selection.
struct PhotoContextMenu: View {
    let library: LibraryModel
    let photo: LibraryPhoto

    var body: some View {
        let targets = library.contextTargets(for: photo)
        let count = targets.count
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
        let tagged = library.speciesTagTargets(targets).count
        // 没有识别出鸟种、或鸟种没有名录信息时不显示这一项 / hidden unless some target has a species with checklist info
        if tagged > 0 {
            Button(tagged == 1 ? "写入鸟种信息" : "写入鸟种信息（\(tagged) 张）") { library.writeSpeciesTags(targets) }
                .help("把鸟名、目科属、IUCN 等级和罕见度写进照片的标题、描述和关键字（会替换原有描述）")
        }
        Divider()
        // 视频、RAF 不能打旗标和评分 / videos and RAF cannot be flagged or rated
        if targets.contains(where: RatingFile.canWrite) {
            Menu("旗标") {
                Button("旗标") { library.setFlag(.picked, for: targets) }
                    .keyboardShortcut("p", modifiers: [])
                Button("排除") { library.setFlag(.rejected, for: targets) }
                    .keyboardShortcut("x", modifiers: [])
                Button("无旗标") { library.setFlag(nil, for: targets) }
                    .keyboardShortcut("u", modifiers: [])
            }
            Menu("评分") {
                ForEach(RatingFile.range.reversed(), id: \.self) { stars in
                    Button(String(repeating: "★", count: stars)) { library.setUserRating(stars, for: targets) }
                        .accessibilityLabel("\(stars) 星")
                        .keyboardShortcut(KeyEquivalent(Character("\(stars)")), modifiers: [])
                }
                Divider()
                Button("清除") { library.setUserRating(nil, for: targets) }
                    .keyboardShortcut("0", modifiers: [])
            }
        }
        Divider()
        Menu(count == 1 ? "移动到" : "将 \(count) 张照片移动到") {
            ForEach(library.topLevelFolders) { folder in
                MoveToFolderMenu(folder: folder, library: library) { library.movePhotos(targets, to: $0) }
            }
        }
        Button(count == 1 ? "移到废纸篓" : "将 \(count) 张照片移到废纸篓") { library.moveToTrash(targets) }
            .keyboardShortcut(.delete, modifiers: [])
    }
}

/// 「移动到」子菜单里的一个文件夹；有子文件夹时展开成下一级，第一项是移到它本身
/// One folder in the "Move to" submenu; with subfolders it opens a further level whose first item is the folder itself.
struct MoveToFolderMenu: View {
    let folder: FolderNode
    let library: LibraryModel
    let onPick: (URL) -> Void

    var body: some View {
        if folder.children.isEmpty {
            Button(folder.name) { onPick(folder.url) }
        } else {
            Menu(folder.name) {
                Button("移到「\(folder.name)」") { onPick(folder.url) }
                Divider()
                ForEach(library.ordered(folder.children)) { MoveToFolderMenu(folder: $0, library: library, onPick: onPick) }
            }
        }
    }
}
