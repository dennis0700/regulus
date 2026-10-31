import AppKit
import RegulusCore
import SwiftUI

/// 侧边栏里的一个文件夹及其子文件夹。照片库根目录默认展开 / A sidebar folder with its subfolders; the library root starts expanded.
struct FolderTree: View {
    /// 右键菜单里需要弹窗的操作，弹窗挂在侧边栏上 / Context-menu actions that need a dialog, presented by the sidebar.
    struct MenuActions {
        let newFolder: (URL) -> Void
        let trash: (FolderNode) -> Void
    }

    let library: LibraryModel
    let folder: FolderNode
    let root: URL
    let actions: MenuActions
    /// 只有顶层文件夹能固定 / Only top-level folders can be pinned.
    var isTopLevel = true
    @State private var isExpanded: Bool?
    /// 有照片拖到这一行上方 / Photos are being dragged over this row.
    @State private var isDropTarget = false

    var body: some View {
        if folder.children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: Binding(get: { isExpanded ?? (folder.url == root) },
                                                set: { isExpanded = $0 })) {
                // 子文件夹也要有自己的 onMove，否则 List 会把拖动当成顶层的移动
                // Subfolders need their own onMove, otherwise List treats the drag as a top-level move
                ForEach(library.ordered(folder.children)) {
                    FolderTree(library: library, folder: $0, root: root, actions: actions, isTopLevel: false)
                }
                .onMove { library.moveSubfolders(of: folder, from: $0, to: $1) }
            } label: {
                row
            }
            // 子文件夹变了就重建这一层：否则侧边栏有时显示为展开却画不出子项（里面的照片被删光后遇到过）。
            // 展开状态存在本视图的 @State 里，不受影响
            // Rebuild this level when its subfolders change: otherwise the sidebar sometimes shows it expanded without
            // drawing the children (seen after emptying a folder). The expansion state lives in this view's @State and
            // survives.
            .id(folder.children.map(\.url))
        }
    }

    private var row: some View {
        let pinned = isTopLevel && library.isPinned(folder.url)
        return Label {
            HStack(spacing: 4) {
                Text(folder.name)
                if pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("已固定")
                }
            }
        } icon: {
            Image(systemName: "folder")
        }
        .badge(folder.count)
        .tag(LibraryModel.SidebarItem.folder(folder.url))
        // 从网格拖照片到这里就移动过来 / photos dragged here from the grid are moved into this folder
        .dropDestination(for: String.self) { payloads, _ in
            let photos = library.draggedPhotos(payloads)
            guard !photos.isEmpty else { return false }
            library.movePhotos(photos, to: folder.url)
            return true
        } isTargeted: { isDropTarget = $0 }
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)).padding(-4)
            }
        }
        .contextMenu {
            Button("在 Finder 中打开") { NSWorkspace.shared.open(folder.url) }
            Button("新建文件夹…") { actions.newFolder(folder.url) }
            Divider()
            if isTopLevel {
                Button(pinned ? "取消固定位置" : "固定位置") { library.togglePin(folder.url) }
                    .help("固定后这个文件夹留在当前位置，不能拖动，拖动其他文件夹也不会挤开它")
            }
            if library.canRemoveFolder(folder.url) {
                Button("从侧边栏移除") { library.removeFolder(folder.url) }
            }
            if library.canTrashFolder(folder.url) {
                Divider()
                Button("移到废纸篓…") { actions.trash(folder) }
            }
        }
    }
}
