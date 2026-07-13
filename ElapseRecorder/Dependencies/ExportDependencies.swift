import AppKit
@preconcurrency import AVFoundation
import ComposableArchitecture
import CoreVideo
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Codec / container → AVFoundation mapping

extension TimelapseVideoCodec {
    var avCodec: AVVideoCodecType {
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

    var avFileType: AVFileType {
        switch self {
        case .mp4:
            .mp4
        case .mov:
            .mov
        }
    }
}

// MARK: - Clients

/// Encodes screenshots into a timelapse video, reporting progress (0...1) as it goes.
nonisolated struct TimelapseExportClient {
    var export: @Sendable (_ request: TimelapseExportRequest) -> AsyncThrowingStream<Double, Error>
}

/// Presents the export save panel — with an accessory view for format and frame rate — and
/// returns the chosen destination plus options. `frameCount` is the number of screenshots
/// being exported, used to estimate the resulting video length.
nonisolated struct ExportPanelClient {
    var present: @Sendable (_ suggestedName: String, _ frameCount: Int) async -> ExportSelection?
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
    static let liveValue = Self { suggestedName, frameCount in
        await present(suggestedName: suggestedName, frameCount: frameCount)
    }

    @MainActor
    private static func present(suggestedName: String, frameCount: Int) async -> ExportSelection? {
        let panel = NSSavePanel()
        let model = ExportAccessoryModel(frameCount: frameCount)

        panel.allowedContentTypes = [model.container.contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let accessory = NSHostingView(
            rootView: ExportOptionsAccessory(model: model) { [weak panel] container in
                panel?.allowedContentTypes = [container.contentType]
            }
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
private enum TimelapseEncoder {
    static func encode(
        _ request: TimelapseExportRequest,
        progress: @Sendable (Double) -> Void
    ) async throws {
        guard !request.imageURLs.isEmpty else { throw TimelapseExportError.noFrames }

        let canvas = try canvasSize(for: request.imageURLs)
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
        let frameCount = request.imageURLs.count
        // Each consecutive pair contributes 1 "hold" frame plus N crossfade frames, and the
        // very last screenshot is held once at the end.
        let outputFrameCount = frameCount == 1 ? 1 : frameCount + (frameCount - 1) * interpolation

        var emitted = 0
        var lastReportedPercent = -1
        /// Report at most ~101 times (whole-percent steps). Yielding progress for every one of
        /// a very long export's frames (10k+) would flood the main-actor reducer with actions
        /// and make the UI unresponsive, so we coalesce to visible increments.
        func report() {
            let fraction = Double(emitted) / Double(outputFrameCount)
            let percent = Int(fraction * 100)
            if percent != lastReportedPercent {
                lastReportedPercent = percent
                progress(fraction)
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
        }

        do {
            if frameCount == 1 {
                let image = try loadImage(at: request.imageURLs[0])
                try await append { context in drawFrame(image, in: context, canvas: canvas) }
            } else {
                var current = try loadImage(at: request.imageURLs[0])
                for index in 0 ..< frameCount - 1 {
                    let next = try loadImage(at: request.imageURLs[index + 1])

                    // Hold the current screenshot, then dissolve toward the next one. Drawing
                    // `current` fully opaque and compositing `next` over it at alpha f yields a
                    // true crossfade (current·(1-f) + next·f), which stays fully opaque — unlike
                    // fading both, which dips translucent and shows the background mid-transition.
                    try await append { context in drawFrame(current, in: context, canvas: canvas) }
                    for step in stride(from: 1, through: interpolation, by: 1) {
                        let progressFraction = Double(step) / Double(interpolation + 1)
                        try await append { context in
                            drawFrame(current, in: context, canvas: canvas)
                            drawFrame(next, in: context, canvas: canvas, alpha: progressFraction, clearBackground: false)
                        }
                    }
                    current = next
                }
                // Hold the final screenshot.
                try await append { context in drawFrame(current, in: context, canvas: canvas) }
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

    /// The smallest even-sized canvas that fits every frame (H.264/HEVC want even sides).
    private static func canvasSize(for urls: [URL]) throws -> CGSize {
        var maxWidth = 0
        var maxHeight = 0

        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else {
                throw TimelapseExportError.unreadableImage(url)
            }
            maxWidth = max(maxWidth, width)
            maxHeight = max(maxHeight, height)
        }

        return CGSize(width: max(2, maxWidth + maxWidth % 2), height: max(2, maxHeight + maxHeight % 2))
    }

    private static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw TimelapseExportError.unreadableImage(url)
        }
        return image
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
}
