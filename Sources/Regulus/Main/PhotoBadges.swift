import RegulusCore
import SwiftUI

/// 旗标图标：旗标为白色旗子，排除为白色叉 / Flag icon: a white flag for picked, a white cross for rejected.
struct FlagMark: View {
    let flag: PhotoFlag

    var body: some View {
        Image(systemName: flag.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
            .help(flag.title)
            .accessibilityLabel(flag.title)
    }
}

/// 缩略图右上角的星级：只画实心星 / Stars in the thumbnail's top-right corner: filled stars only.
struct StarsMark: View {
    let stars: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<stars, id: \.self) { _ in
                Image(systemName: "star.fill")
            }
        }
        .font(.caption2)
        .foregroundStyle(.yellow)
        .padding(3)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
        .help(String(localized: "按 1–5 给所选照片评分（写入照片文件），按 0 清除评分"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stars) 星")
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(.black)
            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
    }
}
