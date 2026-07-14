import AppKit
@preconcurrency import AVFoundation
import ComposableArchitecture
import CoreVideo
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Codec / container → AVFoundation mapping

extension TimelapseVideoCodec {
    nonisolated var avCodec: AVVideoCodecType {
        switch self {
        case .h264:
            .h264
        case .hevc:
            .hevc
        }
    }
}

extension TimelapseVideoContainer {
    var contentType: UTType {
        switch self {
        case .mp4:
            .mpeg4Movie
        case .mov:
            .quickTimeMovie
        }
    }

    nonisolated var avFileType: AVFileType {
        switch self {
        case .mp4:
            .mp4
        case .mov:
            .mov
        }
    }
}

// MARK: - Clients

/// Encodes screenshots into a timelapse video, reporting frame progress as it goes.
nonisolated struct TimelapseExportClient {
    var export: @Sendable (_ request: TimelapseExportRequest) -> AsyncThrowingStream<TimelapseExportProgress, Error>
}

/// Presents the export save panel — with an accessory view for format and frame rate — and
/// returns the chosen destination plus options. `frameHashes` are the perceptual hashes of the
/// frames being exported (order matters), used to estimate length and to power the trim and
/// near-duplicate options live in the accessory.
nonisolated struct ExportPanelClient {
    var present: @Sendable (_ suggestedName: String, _ frameHashes: [UInt64]) async -> ExportSelection?
}

// MARK: - Live values

extension TimelapseExportClient: DependencyKey {
    static let liveValue = Self { request in
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await TimelapseEncoder.encode(request) { progress in
                        continuation.yield(progress)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let testValue = Self { _ in
        AsyncThrowingStream {
            reportIssue("TimelapseExportClient.export is unimplemented")
            $0.finish()
        }
    }
}

extension ExportPanelClient: DependencyKey {
    static let liveValue = Self { suggestedName, frameHashes in
        await present(suggestedName: suggestedName, frameHashes: frameHashes)
    }

    @MainActor
    private static func present(suggestedName: String, frameHashes: [UInt64]) async -> ExportSelection? {
        let panel = NSSavePanel()
        let model = ExportAccessoryModel(frameHashes: frameHashes)

        panel.allowedContentTypes = [model.container.contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let accessory = NSHostingView(rootView: AnyView(EmptyView()))
        accessory.rootView = AnyView(
            ExportOptionsAccessory(
                model: model,
                onContainerChange: { [weak panel] container in
                    panel?.allowedContentTypes = [container.contentType]
                },
                onContentSizeChange: { [weak accessory] size in
                    // The save panel sizes itself from the accessory's frame, so grow/shrink the
                    // hosting view as the SwiftUI content changes height (e.g. expanding the
                    // Advanced disclosure or the trim fields) instead of clipping it.
                    guard let accessory else { return }
                    let newSize = NSSize(width: size.width, height: size.height)
                    if accessory.frame.size != newSize {
                        accessory.setFrameSize(newSize)
                    }
                }
            )
        )
        accessory.setFrameSize(accessory.fittingSize)
        panel.accessoryView = accessory

        // Present as a window-attached sheet (slides from the title bar, dims the window),
        // matching SwiftUI's file exporter. Fall back to a modal panel only if there's no
        // window to host the sheet.
        let response: NSApplication.ModalResponse
        if let window = hostWindow() {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }

        guard response == .OK, let url = panel.url else { return nil }
        return ExportSelection(destinationURL: url, options: model.options)
    }

    @MainActor
    private static func hostWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    static let testValue = Self { _, _ in
        reportIssue("ExportPanelClient.present is unimplemented")
        return nil
    }
}

extension DependencyValues {
    var timelapseExportClient: TimelapseExportClient {
        get { self[TimelapseExportClient.self] }
        set { self[TimelapseExportClient.self] = newValue }
    }

    var exportPanelClient: ExportPanelClient {
        get { self[ExportPanelClient.self] }
        set { self[ExportPanelClient.self] = newValue }
    }
}

// MARK: - Encoder

/// Offline AVFoundation timelapse encoder. Frames are letterboxed onto a canvas sized to
/// the largest frame, so windows that resize mid-session don't distort or crop.
private nonisolated enum TimelapseEncoder {
    static func encode(
        _ request: TimelapseExportRequest,
        progress: @Sendable (TimelapseExportProgress) -> Void
    ) async throws {
        let frames = request.frames
        guard !frames.isEmpty else { throw TimelapseExportError.noFrames }

        let canvas = try canvasSize(for: frames, maxDimension: request.maxOutputDimension)
        try? FileManager.default.removeItem(at: request.destinationURL)

        let writer = try AVAssetWriter(outputURL: request.destinationURL, fileType: request.container.avFileType)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: request.codec.avCodec,
                AVVideoWidthKey: Int(canvas.width),
                AVVideoHeightKey: Int(canvas.height),
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(canvas.width),
                kCVPixelBufferHeightKey as String: Int(canvas.height),
            ]
        )

        guard writer.canAdd(input) else {
            throw TimelapseExportError.encodingFailed("writer rejected the video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let fps = max(1, request.framesPerSecond)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let interpolation = max(0, request.interpolationFrames)
        let frameCount = frames.count
        let outputFrameCount = request.outputFrameCount

        var emitted = 0
        // Report every frame for typical exports so the frame counter advances one-by-one, but
        // cap very long exports (10k+) to ~500 updates so we never flood the main-actor reducer
        // with actions and make the UI unresponsive.
        let reportStride = max(1, outputFrameCount / 500)
        func report() {
            if emitted % reportStride == 0 || emitted == outputFrameCount {
                progress(TimelapseExportProgress(emittedFrames: emitted, totalFrames: outputFrameCount))
            }
        }
        func append(_ draw: (CGContext) -> Void) async throws {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw TimelapseExportError.encodingFailed("missing pixel buffer pool")
            }
            let buffer = try pixelBuffer(canvas: canvas, pool: pool, draw: draw)
            let time = CMTimeMultiply(frameDuration, multiplier: Int32(emitted))
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "frame append failed")
            }
            emitted += 1
            report()
            // Yield between frames so a long, CPU-bound export never monopolizes its executor:
            // this lets progress values and UI updates flow smoothly instead of arriving in a
            // burst at the end.
            await Task.yield()
        }

        // Decode source images on background tasks so decoding (the main cost for HEIC) overlaps
        // with drawing and VideoToolbox encoding. A bounded look-ahead keeps only a few decoded
        // frames resident at once regardless of how long the export is.
        let lookAhead = 3
        var decodeTasks = [Task<SendableImage, Error>?](repeating: nil, count: frameCount)
        func startDecode(_ index: Int) {
            guard index < frameCount, decodeTasks[index] == nil else { return }
            let source = frames[index].frameSource
            decodeTasks[index] = Task.detached(priority: .userInitiated) {
                try await SendableImage(image: loadImage(source, fittingWithin: canvas))
            }
        }
        defer { for task in decodeTasks {
            task?.cancel()
        } }

        // Optional timestamp overlay: format each source frame's capture time once and burn it
        // into that frame's output (its hold plus the crossfade frames leading to the next one).
        let overlayFormat: Date.FormatStyle? = request.timestampOverlay
            ? Date.FormatStyle(date: .abbreviated, time: .standard)
            : nil
        func overlayText(_ index: Int) -> String? {
            overlayFormat.map { frames[index].capturedAt.formatted($0) }
        }

        do {
            for index in 0 ..< min(lookAhead, frameCount) {
                startDecode(index)
            }

            if frameCount == 1 {
                let image = try await decodeTasks[0]!.value.image
                let text = overlayText(0)
                try await append { context in
                    drawFrame(image, in: context, canvas: canvas)
                    if let text { drawTimestamp(text, in: context, canvas: canvas) }
                }
            } else {
                var current = try await decodeTasks[0]!.value.image
                for index in 0 ..< frameCount - 1 {
                    // Keep the decode window full so source `index + lookAhead` decodes while
                    // this pair's frames are drawn and encoded.
                    startDecode(index + lookAhead)

                    let text = overlayText(index)

                    // Hold the current screenshot, then dissolve toward the next one. Drawing
                    // `current` fully opaque and compositing `next` over it at alpha f yields a
                    // true crossfade (current·(1-f) + next·f), which stays fully opaque — unlike
                    // fading both, which dips translucent and shows the background mid-transition.
                    try await append { context in
                        drawFrame(current, in: context, canvas: canvas)
                        if let text { drawTimestamp(text, in: context, canvas: canvas) }
                    }

                    let next = try await decodeTasks[index + 1]!.value.image
                    for step in stride(from: 1, through: interpolation, by: 1) {
                        let progressFraction = Double(step) / Double(interpolation + 1)
                        try await append { context in
                            drawFrame(current, in: context, canvas: canvas)
                            drawFrame(next, in: context, canvas: canvas, alpha: progressFraction, clearBackground: false)
                            if let text { drawTimestamp(text, in: context, canvas: canvas) }
                        }
                    }
                    decodeTasks[index] = nil
                    current = next
                }
                // Hold the final screenshot.
                let lastText = overlayText(frameCount - 1)
                try await append { context in
                    drawFrame(current, in: context, canvas: canvas)
                    if let lastText { drawTimestamp(lastText, in: context, canvas: canvas) }
                }
            }

            input.markAsFinished()
            await writer.finishWriting()

            if writer.status != .completed {
                throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "encoding did not complete")
            }
        } catch {
            // Discard the half-written file on cancellation or failure so we never leave a
            // truncated, unplayable video behind.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: request.destinationURL)
            throw error
        }
    }

    /// A decoded frame that can cross task boundaries. `CGImage` is immutable and safe to read
    /// concurrently, so wrapping it as unchecked-Sendable is sound.
    private struct SendableImage: @unchecked Sendable {
        let image: CGImage
    }

    /// The smallest even-sized canvas that fits every frame (H.264/HEVC want even sides). Uses
    /// each frame's stored pixel size when known, only opening the file's metadata as a fallback.
    /// When `maxDimension` is set, the canvas is scaled down so its longest side fits the cap.
    private static func canvasSize(for frames: [ExportFrame], maxDimension: Int?) throws -> CGSize {
        var maxWidth = 0
        var maxHeight = 0

        for frame in frames {
            let size: CGSize
            if let known = frame.knownPixelSize {
                size = known
            } else if case let .file(url) = frame.frameSource {
                size = try imagePixelSize(at: url)
            } else {
                // Video-backed frame without stored dimensions (practically never happens, since
                // compaction post-dates dimension tracking): rely on sibling frames for the canvas.
                continue
            }
            maxWidth = max(maxWidth, Int(size.width))
            maxHeight = max(maxHeight, Int(size.height))
        }

        if let cap = maxDimension, cap > 0 {
            let longest = max(maxWidth, maxHeight)
            if longest > cap {
                let scale = Double(cap) / Double(longest)
                maxWidth = Int((Double(maxWidth) * scale).rounded())
                maxHeight = Int((Double(maxHeight) * scale).rounded())
            }
        }

        return CGSize(width: max(2, maxWidth + maxWidth % 2), height: max(2, maxHeight + maxHeight % 2))
    }

    private static func imagePixelSize(at url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw TimelapseExportError.unreadableImage(url)
        }
        return CGSize(width: width, height: height)
    }

    /// Decode a source image eagerly and no larger than the canvas needs. Using the thumbnail
    /// API decodes directly at the target size (instead of a lazy full-resolution decode that
    /// would happen on the encoding thread), which keeps the encode loop fed and memory bounded.
    private static func loadImage(_ source: FrameSource, fittingWithin canvas: CGSize) async throws -> CGImage {
        switch source {
        case let .file(url):
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw TimelapseExportError.unreadableImage(url)
            }

            let maxPixelSize = Int(max(canvas.width, canvas.height))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]

            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                throw TimelapseExportError.unreadableImage(url)
            }
            return image

        case let .videoFrame(video, index):
            let asset = AVURLAsset(url: video)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(value: CMTimeValue(index), timescale: CompactionVideo.frameRate)
            do {
                let (image, _) = try await generator.image(at: time)
                return image
            } catch {
                throw TimelapseExportError.unreadableImage(video)
            }
        }
    }

    private static func pixelBuffer(
        canvas: CGSize,
        pool: CVPixelBufferPool,
        draw: (CGContext) -> Void
    ) throws -> CVPixelBuffer {
        var bufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut) == kCVReturnSuccess,
              let buffer = bufferOut
        else {
            throw TimelapseExportError.encodingFailed("could not allocate a frame buffer")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw TimelapseExportError.encodingFailed("could not create a drawing context")
        }

        draw(context)
        return buffer
    }

    /// Draw a single frame aspect-fit and centered. `alpha` enables crossfade dissolves;
    /// `clearBackground` paints black first (skip it when compositing a second image on top).
    private static func drawFrame(
        _ image: CGImage,
        in context: CGContext,
        canvas: CGSize,
        alpha: CGFloat = 1,
        clearBackground: Bool = true
    ) {
        if clearBackground {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: canvas))
        }

        let scale = min(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(x: (canvas.width - drawSize.width) / 2, y: (canvas.height - drawSize.height) / 2)

        context.saveGState()
        context.setAlpha(alpha)
        context.draw(image, in: CGRect(origin: origin, size: drawSize))
        context.restoreGState()
    }

    /// Burn a timestamp into the bottom-left corner with a translucent pill behind it for
    /// legibility. Uses Core Text so it's safe to draw on the background encode task.
    private static func drawTimestamp(_ text: String, in context: CGContext, canvas: CGSize) {
        let fontSize = max(12, canvas.height * 0.028)
        let padding = fontSize * 0.6
        let inset = fontSize * 0.45

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "HelveticaNeue-Medium" as CFString, fontSize, nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: 1, green: 1, blue: 1, alpha: 1
            ),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes) as CFAttributedString
        )

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let pillHeight = ascent + descent + inset * 2
        let pillWidth = textWidth + inset * 2
        let pillRect = CGRect(x: padding, y: padding, width: pillWidth, height: pillHeight)

        context.saveGState()
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        context.addPath(CGPath(roundedRect: pillRect, cornerWidth: inset, cornerHeight: inset, transform: nil))
        context.fillPath()

        context.textPosition = CGPoint(x: padding + inset, y: padding + inset + descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
