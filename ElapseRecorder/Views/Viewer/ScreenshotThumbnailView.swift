import AppKit
import ComposableArchitecture
import CoreGraphics
import SFSafeSymbols
import SwiftUI

struct ScreenshotThumbnailView: View {
    let record: ScreenshotRecord

    @Dependency(\.capturePreferencesClient) private var preferences
    @Dependency(\.thumbnailClient) private var thumbnails
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if let image {
                Image(nsImage: NSImage(cgImage: image, size: image.displaySize))
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemSymbol: .photo)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: record.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // A cache hit shows the thumbnail immediately, so scrolling back to already-seen
        // cells doesn't reload from disk or flash the placeholder.
        if let cached = ThumbnailCache.shared.image(forID: record.id) {
            image = cached
            return
        }

        image = nil
        guard let loaded = try? await thumbnails.thumbnail(
            record.fileURL,
            preferences.thumbnailMaximumPixelSize()
        ) else {
            return
        }

        ThumbnailCache.shared.insert(loaded, forID: record.id)
        image = loaded
    }
}
