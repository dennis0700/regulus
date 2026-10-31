import RegulusCore
import SwiftUI

/// 预览底部的胶片栏：当前列表的全部照片，点击切换，当前那张自动滚到中间
/// The filmstrip under the preview: every photo in the current list; click to switch, the current one stays centred.
struct Filmstrip: View {
    let library: LibraryModel
    let current: URL

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 2) {
                    ForEach(library.visiblePhotos) { photo in
                        FilmstripCell(photo: photo, cache: library.thumbnails, isCurrent: photo.url == current,
                                      flag: library.flag(for: photo))
                            .id(photo.url)
                            .onTapGesture { library.openPreview(photo) }
                            .contextMenu { PhotoContextMenu(library: library, photo: photo) }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: 84)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { withAnimation { proxy.scrollTo(current, anchor: .center) } }
        }
    }
}

struct FilmstripCell: View {
    let photo: LibraryPhoto
    let cache: ThumbnailCache
    let isCurrent: Bool
    let flag: PhotoFlag?
    @State private var thumbnail: Thumbnail?

    var body: some View {
        // 固定格子大小，图片裁切填满 / fixed cell size, image cropped to fill
        Color.clear
            .frame(width: 96, height: 72)
            .overlay {
                if let thumbnail {
                    Image(thumbnail.image, scale: 1, label: Text(photo.name)).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipped()
            .opacity(flag == .rejected ? 0.4 : 1)
            .overlay(alignment: .topTrailing) {
                if photo.isRaw { Badge(text: "R").padding(3) }
                if photo.isVideo { Badge(text: "▶").padding(3) }
            }
            .overlay(alignment: .bottomLeading) {
                if let flag { FlagMark(flag: flag).padding(3) }
            }
            .overlay {
                if isCurrent { Rectangle().strokeBorder(Color.accentColor, lineWidth: 3) }
            }
            .contentShape(Rectangle())
            // 512 与网格小格子那一档共用缓存 / 512 shares cache entries with the grid's small-cell tier
            .task(id: photo) { thumbnail = await cache.thumbnail(for: photo.url, maxPixelSize: 512) }
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
