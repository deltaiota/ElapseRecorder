import AppKit
@preconcurrency import AVFoundation
import ComposableArchitecture
import CoreVideo
import Foundation
import UniformTypeIdentifiers

// MARK: - Clients

/// Encodes screenshots into a timelapse video, reporting progress (0...1) as it goes.
nonisolated struct TimelapseExportClient {
    var export: @Sendable (_ request: TimelapseExportRequest) -> AsyncThrowingStream<Double, Error>
}

/// Asks the user where to save an exported file via a save panel.
nonisolated struct ExportDestinationClient {
    var chooseVideoDestination: @Sendable (_ suggestedName: String) async -> URL?
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

extension ExportDestinationClient: DependencyKey {
    static let liveValue = Self { suggestedName in
        await MainActor.run {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    static let testValue = Self { _ in
        reportIssue("ExportDestinationClient.chooseVideoDestination is unimplemented")
        return nil
    }
}

extension DependencyValues {
    var timelapseExportClient: TimelapseExportClient {
        get { self[TimelapseExportClient.self] }
        set { self[TimelapseExportClient.self] = newValue }
    }

    var exportDestinationClient: ExportDestinationClient {
        get { self[ExportDestinationClient.self] }
        set { self[ExportDestinationClient.self] = newValue }
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

        let writer = try AVAssetWriter(outputURL: request.destinationURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
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
        let total = request.imageURLs.count

        for (index, url) in request.imageURLs.enumerated() {
            try Task.checkCancellation()

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw TimelapseExportError.encodingFailed("missing pixel buffer pool")
            }

            let image = try loadImage(at: url)
            let buffer = try pixelBuffer(for: image, canvas: canvas, pool: pool)
            let time = CMTimeMultiply(frameDuration, multiplier: Int32(index))

            if !adaptor.append(buffer, withPresentationTime: time) {
                throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "frame append failed")
            }

            progress(Double(index + 1) / Double(total))
        }

        input.markAsFinished()
        await writer.finishWriting()

        if writer.status != .completed {
            throw TimelapseExportError.encodingFailed(writer.error?.localizedDescription ?? "encoding did not complete")
        }
    }

    /// The smallest even-sized canvas that fits every frame (H.264 wants even dimensions).
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

    private static func pixelBuffer(for image: CGImage, canvas: CGSize, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
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

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))

        // Aspect-fit the frame, centered, so differing window sizes letterbox cleanly.
        let scale = min(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(x: (canvas.width - drawSize.width) / 2, y: (canvas.height - drawSize.height) / 2)
        context.draw(image, in: CGRect(origin: origin, size: drawSize))

        return buffer
    }
}
