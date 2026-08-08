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
        guard request.source.count > 0 else { throw TimelapseExportError.noFrames }

        let canvas = try await canvasSize(for: request.source, maxDimension: request.maxOutputDimension)
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
        let outputFrameCount = request.outputFrameCount
        let maximumPixelSize = Int(max(canvas.width, canvas.height))
        let reader = FrameReader.shared
        let overlayFormat: Date.FormatStyle? = request.timestampOverlay
            ? Date.FormatStyle(date: .abbreviated, time: .standard)
            : nil

        var emitted = 0
        let reportStride = max(1, outputFrameCount / 500)
        func report() {
            if emitted % reportStride == 0 || emitted == outputFrameCount {
                progress(TimelapseExportProgress(emittedFrames: emitted, totalFrames: outputFrameCount))
            }
        }
        func append(_ draw: (CGContext) -> Void) async throws {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else {
                    throw TimelapseExportError.encodingFailed(
                        writer.error?.localizedDescription ?? "video writer stopped accepting frames"
                    )
                }
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
            await Task.yield()
        }

        do {
            var iterator = request.source.stream().makeAsyncIterator()
            guard var currentFrame = try await iterator.next() else {
                throw TimelapseExportError.noFrames
            }
            var current = try await reader.image(
                for: currentFrame.frameSource,
                maximumPixelSize: maximumPixelSize
            )

            while let nextFrame = try await iterator.next() {
                // Decode the next descriptor while the current image is drawn and submitted.
                // FrameReader applies the process-wide hard concurrency bound.
                let nextDecode = Task {
                    try SendableImage(await reader.image(
                        for: nextFrame.frameSource,
                        maximumPixelSize: maximumPixelSize
                    ))
                }
                defer { nextDecode.cancel() }
                let text = overlayFormat.map { currentFrame.capturedAt.formatted($0) }
                try await append { context in
                    drawFrame(current, in: context, canvas: canvas)
                    if let text { drawTimestamp(text, in: context, canvas: canvas) }
                }
                let next = try await nextDecode.value.value

                for step in stride(from: 1, through: interpolation, by: 1) {
                    let fraction = Double(step) / Double(interpolation + 1)
                    try await append { context in
                        drawFrame(current, in: context, canvas: canvas)
                        drawFrame(next, in: context, canvas: canvas, alpha: fraction, clearBackground: false)
                        if let text { drawTimestamp(text, in: context, canvas: canvas) }
                    }
                }
                currentFrame = nextFrame
                current = next
            }

            let finalText = overlayFormat.map { currentFrame.capturedAt.formatted($0) }
            try await append { context in
                drawFrame(current, in: context, canvas: canvas)
                if let finalText { drawTimestamp(finalText, in: context, canvas: canvas) }
            }

            input.markAsFinished()
            await writer.finishWriting()
            if writer.status != .completed {
                throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "encoding did not complete")
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: request.destinationURL)
            throw error
        }
    }

    private struct SendableImage: @unchecked Sendable {
        let value: CGImage
        init(_ value: CGImage) {
            self.value = value
        }
    }

    /// The smallest even-sized canvas that fits every frame (H.264/HEVC want even sides).
    /// Descriptor streaming makes this first pass constant-memory even for very large scopes.
    private static func canvasSize(for source: ExportFrameStream, maxDimension: Int?) async throws -> CGSize {
        var maxWidth = 0
        var maxHeight = 0

        for try await frame in source.stream() {
            try Task.checkCancellation()
            let size = if let known = frame.knownPixelSize {
                known
            } else {
                try await FrameReader.shared.pixelSize(for: frame.frameSource)
            }
            maxWidth = max(maxWidth, Int(size.width))
            maxHeight = max(maxHeight, Int(size.height))
        }

        guard maxWidth > 0, maxHeight > 0 else { throw TimelapseExportError.noFrames }
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
