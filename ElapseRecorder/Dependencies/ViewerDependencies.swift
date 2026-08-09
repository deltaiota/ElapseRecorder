@preconcurrency import AppKit
import ApplicationServices
import AVFoundation
import Chronicle
import ComposableArchitecture
import CoreGraphics
import Defaults
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

extension PersistenceClient: DependencyKey {
    static let liveValue = Self.live()
}

extension ThumbnailClient: DependencyKey {
    static let liveValue = Self { source, maximumPixelSize in
        try await FrameReader.shared.image(
            for: source,
            maximumPixelSize: max(1, maximumPixelSize)
        )
    }

    static let testValue = Self { _, _ in
        reportIssue("ThumbnailClient.thumbnail is unimplemented")
        throw CancellationError()
    }
}

nonisolated enum ImageSourceSizing {
    static func clampedMaximumPixelSize(for source: CGImageSource, requested: Int) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return max(1, requested)
        }

        return max(1, min(requested, max(width, height)))
    }
}

extension ImageLoadingClient: DependencyKey {
    static let liveValue = Self { url in
        try await Task.detached(priority: .high) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw CaptureEngineError.fileWriteFailed(url)
            }

            return image
        }.value
    }
}

extension FileRevealClient: DependencyKey {
    static let liveValue = Self { url in
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

extension LoggingClient: DependencyKey {
    static let liveValue = Self { level, message, metadata in
        Logger.shared.log(message, level: level, tags: [.capture], metadata: metadata)
    }

    /// Logging is a fire-and-forget diagnostic side effect, so tests get a silent no-op
    /// by default instead of having to override it everywhere a logged path is exercised.
    static let testValue = Self { _, _, _ in }
}
