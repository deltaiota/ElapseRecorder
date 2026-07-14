import AppKit
import ComposableArchitecture
import CoreGraphics
import SFSafeSymbols
import SwiftUI

struct ScreenshotThumbnailView: View {
    let record: ScreenshotRecord
    var prefetch: [ScreenshotRecord] = []

    @Dependency(\.capturePreferencesClient) private var preferences
    @Dependency(\.thumbnailClient) private var thumbnails
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: NSImage(cgImage: image, size: image.displaySize))
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(.quaternary)
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
            await prefetchUpcoming()
            return
        }

        image = nil

        // Debounce: a cell that only flashes past during a fast scroll has its `.task`
        // cancelled before this delay elapses, so its thumbnail is never fetched. Only
        // cells that linger long enough actually load.
        try? await Task.sleep(for: .milliseconds(90))
        guard !Task.isCancelled else { return }

        guard let loaded = try? await thumbnails.thumbnail(
            record.frameSource,
            preferences.thumbnailMaximumPixelSize()
        ) else {
            return
        }

        ThumbnailCache.shared.insert(loaded, forID: record.id)
        image = loaded
        await prefetchUpcoming()
    }

    /// Warm the next few thumbnails once this cell has settled. Tied to the cell's task,
    /// so a fast scroll (which cancels the task) also stops the prefetch chain.
    private func prefetchUpcoming() async {
        guard !prefetch.isEmpty else { return }
        let maximumPixelSize = preferences.thumbnailMaximumPixelSize()

        for upcoming in prefetch {
            if Task.isCancelled { return }
            guard ThumbnailCache.shared.image(forID: upcoming.id) == nil else { continue }
            if let loaded = try? await thumbnails.thumbnail(upcoming.frameSource, maximumPixelSize) {
                ThumbnailCache.shared.insert(loaded, forID: upcoming.id)
            }
        }
    }
}
