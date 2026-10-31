import RegulusCore
import SwiftUI

struct PhotoCell: View {
    let photo: LibraryPhoto
    let side: Double
    let pixelSize: Int
    let cache: ThumbnailCache
    let isSelected: Bool
    let userStars: Int?
    let flag: PhotoFlag?
    let speciesName: String?
    @State private var thumbnail: Thumbnail?

    private var imageHeight: Double {
        guard let thumbnail, thumbnail.image.width > 0 else { return side * 2 / 3 }
        return side * min(1, Double(thumbnail.image.height) / Double(thumbnail.image.width))
    }

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumbnail {
                    Image(thumbnail.image, scale: 1, label: Text(photo.name))
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        // 标记排除的变暗，一眼能看出来 / dim rejected photos so they stand out
                        .opacity(flag == .rejected ? 0.4 : 1)
                        .overlay(alignment: .topLeading) {
                            if photo.isRaw { Badge(text: "RAW").padding(5) }
                            if photo.isVideo { Badge(text: String(localized: "视频")).padding(5) }
                        }
                        .overlay(alignment: .topTrailing) {
                            if let userStars { StarsMark(stars: userStars).padding(5) }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if let flag { FlagMark(flag: flag).padding(5) }
                        }
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .aspectRatio(3 / 2, contentMode: .fit)
                }
            }
            // 高度按照片比例（竖拍最多到正方形，没出图时按 3:2）：全是横拍的一行就不会留出正方形的空白；
            // 图片贴底，文字紧跟在下面
            // Height follows the photo's aspect (portraits up to a square, 3:2 before the image loads), so a row of
            // landscape shots doesn't reserve square-sized gaps; the image sits at the bottom, right above its text
            .frame(width: side, height: imageHeight, alignment: .bottom)
            // 图片和文字之间多留一点，文字各行之间仍是 4 / a little more room between image and text; text lines stay 4 apart
            .padding(.bottom, 6)

            Text(photo.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(thumbnail.map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
            // 鸟种行总是占位，有没有鸟名的格子一样高 / the species line always takes room so all cells match in height
            Text(speciesName ?? " ")
                .font(.caption)
                .lineLimit(1)
        }
        .frame(width: side)
        .contentShape(Rectangle())
        // 照片被改写（修改时间变了）或尺寸档位变了就重新取图 / reload when the file is rewritten or the size tier changes
        .task(id: [AnyHashable(pixelSize), AnyHashable(photo)]) {
            thumbnail = await cache.thumbnail(for: photo.url, maxPixelSize: pixelSize)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
