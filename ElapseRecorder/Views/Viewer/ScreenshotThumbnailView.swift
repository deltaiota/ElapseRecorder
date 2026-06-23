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
            image = nil
            image = try? await thumbnails.thumbnail(
                record.fileURL,
                preferences.thumbnailMaximumPixelSize()
            )
        }
    }
}
