import RegulusCore
import SwiftUI

struct Sidebar: View {
    @Bindable var library: LibraryModel
    @State private var addingFolders = false
    /// 正在其中新建文件夹的父文件夹 / The folder a new folder is being created in.
    @State private var newFolderParent: URL?
    @State private var newFolderName = ""
    /// 等待确认移到废纸篓的文件夹 / The folder awaiting confirmation to move to the Trash.
    @State private var folderToTrash: FolderNode?

    private var menuActions: FolderTree.MenuActions {
        FolderTree.MenuActions(
            newFolder: { parent in
                newFolderName = String(localized: "未命名文件夹")
                newFolderParent = parent
            },
            trash: { folderToTrash = $0 })
    }

    var body: some View {
        List(selection: $library.sidebarSelection) {
            Section("照片库") {
                Label("所有照片", systemImage: "photo.on.rectangle")
                    .badge(library.snapshot?.photos.count ?? 0)
                    .tag(LibraryModel.SidebarItem.all)
                Label("最近导入", systemImage: "square.and.arrow.down")
                    .badge(library.recentImport.count)
                    .tag(LibraryModel.SidebarItem.recentImport)
            }
            if let snapshot = library.snapshot {
                Section {
                    // 固定位置的文件夹不能拖，拖别的也不会挤开它 / fixed folders can't be dragged and aren't pushed aside
                    ForEach(library.topLevelFolders) { folder in
                        FolderTree(library: library, folder: folder, root: snapshot.root, actions: menuActions)
                            .moveDisabled(library.isPinned(folder.url))
                    }
                    .onMove { library.moveFolders(from: $0, to: $1) }
                } header: {
                    HStack {
                        Text("文件夹")
                        Spacer()
                        Button { addingFolders = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("添加文件夹…")
                            .accessibilityLabel("添加文件夹")
                            // 与下方行尾的照片数对齐 / line up with the photo counts in the rows below
                            .padding(.trailing, 16)
                    }
                }
            }
            Section("旗标") {
                let counts = library.flagCounts
                ForEach(PhotoFlag.allCases, id: \.self) { flag in
                    Label(flag.title, systemImage: flag.systemImage)
                        .badge(counts[flag] ?? 0)
                        .tag(LibraryModel.SidebarItem.flag(flag))
                        .contextMenu {
                            if flag == .rejected {
                                let count = counts[.rejected] ?? 0
                                Button("将 \(count) 张照片移到废纸篓") {
                                    library.moveToTrash(library.rejectedPhotos.map(\.url))
                                }
                                .disabled(count == 0)
                            }
                        }
                }
            }
            Section("评分") {
                let counts = library.starCounts
                ForEach(RatingFile.range.reversed(), id: \.self) { stars in
                    Label {
                        Text(String(repeating: "★", count: stars))
                            .accessibilityLabel("\(stars) 星")
                    } icon: {
                        Image(systemName: "rectangle.stack")
                    }
                    .badge(counts[stars] ?? 0)
                    .tag(LibraryModel.SidebarItem.stars(stars))
                }
            }
        }
        .listStyle(.sidebar)
        // 底部空白处显示所看照片的鸟种名录信息 / the checklist info of the photo being looked at, in the empty space below
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let photo = library.inspectedPhoto, let info = library.speciesInfo(for: photo) {
                SpeciesPanel(info: info)
            }
        }
        .fileImporter(isPresented: $addingFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { library.addFolders(urls) }
        }
        .alert("新建文件夹", isPresented: Binding(get: { newFolderParent != nil },
                                              set: { if !$0 { newFolderParent = nil } })) {
            TextField("名称", text: $newFolderName)
            Button("创建") {
                if let parent = newFolderParent { library.createFolder(named: newFolderName, in: parent) }
            }
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        } message: {
            Text("在「\(newFolderParent?.lastPathComponent ?? "")」里新建")
        }
        .confirmationDialog("把「\(folderToTrash?.name ?? "")」移到废纸篓？",
                            isPresented: Binding(get: { folderToTrash != nil }, set: { if !$0 { folderToTrash = nil } }),
                            presenting: folderToTrash) { folder in
            Button("移到废纸篓", role: .destructive) { library.moveFolderToTrash(folder.url) }
            Button("取消", role: .cancel) {}
        } message: { folder in
            Text("文件夹里的所有文件（包括 \(folder.count) 张照片，以及视频等其他文件）都会移到废纸篓，可以在 Finder 里放回原处。")
        }
    }
}
