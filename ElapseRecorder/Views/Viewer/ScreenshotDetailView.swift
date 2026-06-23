import AppKit
import ComposableArchitecture
import CoreGraphics
import SFSafeSymbols
import SwiftUI

struct ScreenshotDetailView: View {
    let record: ScreenshotRecord
    let revealInFinder: () -> Void

    @Dependency(\.imageLoadingClient) private var images
    @State private var image: CGImage?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                if let image {
                    Image(nsImage: NSImage(cgImage: image, size: image.displaySize))
                        .resizable()
                        .scaledToFit()
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Could not load image",
                        systemSymbol: .exclamationmarkTriangle,
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 640, minHeight: 420)

            Group {
                Text(record.capturedAt, format: .dateTime.year().month().day().hour().minute().second())
                Text(record.fileURL.path(percentEncoded: false))
                    .font(.caption)
                    .textSelection(.enabled)
                Text("\(record.fileSizeBytes) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Reveal in Finder") {
                    revealInFinder()
                }
            }
        }
        .padding()
        .task(id: record.id) {
            do {
                image = try await images.fullSizeImage(record.fileURL)
                errorMessage = nil
            } catch {
                image = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
