import SwiftUI
import UIKit

/// Channel logo with downsampled, cached loading and an initials placeholder.
struct LogoImage: View {
    let url: URL?
    let name: String
    var size: CGFloat = 44
    var cornerRadius: CGFloat = Theme.smallCornerRadius

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var pixelSize: CGFloat { size * displayScale }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surface)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(size * 0.12)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ImagePipeline.shared.cachedImage(for: url, maxPixelSize: pixelSize) {
                image = cached
                return
            }
            image = nil
            image = await ImagePipeline.shared.image(for: url, maxPixelSize: pixelSize)
        }
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "|" }).prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "TV" : letters.uppercased()
    }
}

/// Remote thumbnail (YouTube results) using the same pipeline, at a 16:9 aspect.
struct ThumbnailImage: View {
    let url: URL?
    var width: CGFloat = 128

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.surface)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "play.rectangle").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            image = await ImagePipeline.shared.image(for: url, maxPixelSize: width * displayScale)
        }
    }
}
