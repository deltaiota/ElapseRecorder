import AVFoundation
import ComposableArchitecture
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Clients

/// Encodes a window's standalone frames into a single HEVC video (color-managed, near-lossless
/// at the configured quality). Returns the resulting file size in bytes.
nonisolated struct FrameVideoCompactorClient {
    var compact: @Sendable (_ plan: WindowCompactionPlan, _ quality: Double) async throws -> Int
}

/// Decodes a single frame image out of a compacted window video.
nonisolated struct VideoFrameExtractorClient {
    var image: @Sendable (_ videoURL: URL, _ frameIndex: Int) async throws -> CGImage
    /// Extracts a frame and writes it to a temporary HEIC file, returning that URL. Used by
    /// Quick Look, which needs a real file to preview.
    var temporaryImageFile: @Sendable (_ videoURL: URL, _ frameIndex: Int) async throws -> URL
}

enum CompactionError: Error, Equatable {
    case noFrames
    case sourceUnreadable(URL)
    case encoderUnavailable
    case verificationFailed(expected: Int, found: Int)
}

// MARK: - Live encoder

extension FrameVideoCompactorClient: DependencyKey {
    static let liveValue = Self { plan, quality in
        try await CompactionEncoder.encode(plan: plan, quality: quality)
    }

    static let testValue = liveValue
}

private nonisolated enum CompactionEncoder {
    static func encode(plan: WindowCompactionPlan, quality: Double) async throws -> Int {
        let frames = plan.frames
        guard !frames.isEmpty else { throw CompactionError.noFrames }

        var width = plan.canvasWidth
        var height = plan.canvasHeight
        if width <= 0 || height <= 0 {
            let first = try loadImage(frames[0].sourceURL)
            width = first.width
            height = first.height
        }
        width = max(2, width - (width % 2))
        height = max(2, height - (height % 2))

        let output = plan.outputURL
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: quality],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else { throw CompactionError.encoderUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CompactionError.encoderUnavailable }
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        defer {}

        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let image = try loadImage(frame.sourceURL)
            guard let pool = adaptor.pixelBufferPool else { throw CompactionError.encoderUnavailable }

            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let buffer = pixelBuffer
            else {
                throw CompactionError.encoderUnavailable
            }
            CVBufferSetAttachments(buffer, [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ] as CFDictionary, .shouldPropagate)

            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if Task.isCancelled {
                input.markAsFinished()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            }
            adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CompactionVideo.frameRate)
            )
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw writer.error ?? CompactionError.encoderUnavailable
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        return size ?? 0
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else {
            throw CompactionError.sourceUnreadable(url)
        }
        return image
    }
}

// MARK: - Live extractor

extension VideoFrameExtractorClient: DependencyKey {
    static let liveValue = Self(
        image: { videoURL, frameIndex in
            try await extractFrame(videoURL: videoURL, frameIndex: frameIndex)
        },
        temporaryImageFile: { videoURL, frameIndex in
            let image = try await extractFrame(videoURL: videoURL, frameIndex: frameIndex)
            let url = FileManager.default.temporaryDirectory
                .appending(path: "elapse-ql-\(UUID().uuidString).heic")
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else {
                throw CompactionError.encoderUnavailable
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw CompactionError.encoderUnavailable
            }
            return url
        }
    )

    static let testValue = liveValue

    private static func extractFrame(videoURL: URL, frameIndex: Int) async throws -> CGImage {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(value: CMTimeValue(frameIndex), timescale: CompactionVideo.frameRate)
        let (image, _) = try await generator.image(at: time)
        return image
    }
}

// MARK: - Registration

extension DependencyValues {
    var frameVideoCompactorClient: FrameVideoCompactorClient {
        get { self[FrameVideoCompactorClient.self] }
        set { self[FrameVideoCompactorClient.self] = newValue }
    }

    var videoFrameExtractorClient: VideoFrameExtractorClient {
        get { self[VideoFrameExtractorClient.self] }
        set { self[VideoFrameExtractorClient.self] = newValue }
    }
}
