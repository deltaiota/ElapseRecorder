@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

nonisolated struct FrameReaderDiagnostics: Equatable {
    let createdVideoDecoders: Int
    let activeDecodes: Int
    let maximumObservedConcurrentDecodes: Int
}

/// Reads immutable spool images and sealed video assets. Decode permits bound global work while a
/// small actor-isolated LRU reuses one serialized AVAssetImageGenerator per immutable video asset.
/// File decodes and distinct video assets can proceed concurrently; cache mutation never does.
final nonisolated class FrameReader: @unchecked Sendable {
    static let shared = FrameReader()

    private let cache: VideoDecoderCache
    private let limiter: DecodeLimiter

    init(maximumConcurrentDecodes: Int = 3, videoCacheLimit: Int = 2) {
        limiter = DecodeLimiter(limit: maximumConcurrentDecodes)
        cache = VideoDecoderCache(limit: videoCacheLimit)
    }

    func image(for source: FrameSource, maximumPixelSize: Int? = nil) async throws -> CGImage {
        try await limiter.acquire()
        do {
            try Task.checkCancellation()
            let image: CGImage
            switch source {
            case let .file(url):
                image = try await Task.detached(priority: .userInitiated) {
                    try Self.image(at: url, maximumPixelSize: maximumPixelSize)
                }.value
            case let .videoFrame(video, presentationTime):
                let decoder = await cache.decoder(for: video, maximumPixelSize: maximumPixelSize)
                image = try await decoder.image(at: presentationTime)
            }
            await limiter.release()
            return image
        } catch {
            await limiter.release()
            throw error
        }
    }

    /// The caller controls batch size; the decode limiter independently enforces the configured
    /// hard concurrency bound. Results preserve source order.
    func images(for sources: [FrameSource], maximumPixelSize: Int? = nil) async throws -> [CGImage] {
        try await withThrowingTaskGroup(of: (Int, SendableImage).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    try (index, SendableImage(await self.image(for: source, maximumPixelSize: maximumPixelSize)))
                }
            }
            var ordered = [CGImage?](repeating: nil, count: sources.count)
            for try await(index, image) in group {
                ordered[index] = image.value
            }
            return ordered.compactMap { $0 }
        }
    }

    func pixelSize(for source: FrameSource) async throws -> CGSize {
        switch source {
        case let .file(url):
            return try await Task.detached(priority: .utility) {
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int
                else { throw TimelapseExportError.unreadableImage(url) }
                return CGSize(width: width, height: height)
            }.value
        case let .videoFrame(video, _):
            let decoder = await cache.decoder(for: video, maximumPixelSize: nil)
            return try await decoder.pixelSize()
        }
    }

    func diagnostics() async -> FrameReaderDiagnostics {
        let limiterState = await limiter.diagnostics()
        return FrameReaderDiagnostics(
            createdVideoDecoders: await cache.createdDecoderCount(),
            activeDecodes: limiterState.active,
            maximumObservedConcurrentDecodes: limiterState.maximumObserved
        )
    }

    static func mediaTime(for presentationTime: FramePresentationTime) -> CMTime {
        CMTime(
            value: CMTimeValue(presentationTime.value),
            timescale: CMTimeScale(presentationTime.timescale)
        )
    }

    private static func image(at url: URL, maximumPixelSize: Int?) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw TimelapseExportError.unreadableImage(url)
        }
        if let maximumPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw TimelapseExportError.unreadableImage(url)
            }
            return image
        }
        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else { throw TimelapseExportError.unreadableImage(url) }
        return image
    }

    private struct SendableImage: @unchecked Sendable {
        let value: CGImage
        init(_ value: CGImage) {
            self.value = value
        }
    }
}

private actor VideoDecoderCache {
    private struct Entry {
        let url: URL
        let maximumPixelSize: Int?
        let decoder: VideoDecoder
    }

    private let limit: Int
    private var entries: [Entry] = []
    private var created = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func decoder(for url: URL, maximumPixelSize: Int?) -> VideoDecoder {
        if let index = entries.firstIndex(where: {
            $0.url == url && $0.maximumPixelSize == maximumPixelSize
        }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.decoder
        }
        let decoder = VideoDecoder(url: url, maximumPixelSize: maximumPixelSize)
        entries.append(Entry(url: url, maximumPixelSize: maximumPixelSize, decoder: decoder))
        created += 1
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        return decoder
    }

    func createdDecoderCount() -> Int {
        created
    }
}

/// AVAssetImageGenerator is not documented as safe for overlapping requests, so each cached asset
/// owns a tiny actor. This still permits distinct assets and spool images to decode concurrently.
private actor VideoDecoder {
    private let url: URL
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator

    init(url: URL, maximumPixelSize: Int?) {
        self.url = url
        asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        if let maximumPixelSize {
            generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        }
    }

    func image(at presentationTime: FramePresentationTime) async throws -> CGImage {
        do {
            let time = FrameReader.mediaTime(for: presentationTime)
            let (image, _) = try await generator.image(at: time)
            return image
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TimelapseExportError.unreadableImage(url)
        }
    }

    func pixelSize() async throws -> CGSize {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw TimelapseExportError.unreadableImage(url)
            }
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let size = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
            guard size.width > 0, size.height > 0 else {
                throw TimelapseExportError.unreadableImage(url)
            }
            return size
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TimelapseExportError.unreadableImage(url)
        }
    }
}

private actor DecodeLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var active = 0
    private var maximumObserved = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            maximumObserved = max(maximumObserved, active)
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if !waiters.isEmpty {
            // Transfer the existing permit directly; never expose a transient free slot.
            waiters.removeFirst().continuation.resume()
        } else {
            active = max(0, active - 1)
        }
    }

    func diagnostics() -> (active: Int, maximumObserved: Int) {
        (active, maximumObserved)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
