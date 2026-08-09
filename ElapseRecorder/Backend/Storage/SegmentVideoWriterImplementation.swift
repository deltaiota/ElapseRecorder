@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

nonisolated enum SegmentVideoWriterImplementation {
    static func writeAndVerify(
        manifest: SegmentJobManifest,
        quality: Double
    ) async throws -> SegmentWriteVerification {
        try validate(manifest)
        let outputURL = manifest.partialURL
        guard !FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            throw StorageCoordinatorError.readyAssetAlreadyExists(outputURL)
        }
        guard !FileManager.default.fileExists(atPath: manifest.finalURL.path(percentEncoded: false)) else {
            throw StorageCoordinatorError.readyAssetAlreadyExists(manifest.finalURL)
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: outputURL) }
        }
        let context = try makeWriterContext(manifest: manifest, quality: quality)
        for frame in manifest.frames {
            try await append(frame, manifest: manifest, context: context)
        }
        context.input.markAsFinished()
        await context.writer.finishWriting()
        guard context.writer.status == .completed else {
            throw context.writer.error ?? StorageCoordinatorError.segmentWriterUnavailable
        }
        let verification = try await verify(manifest: manifest, url: outputURL)
        completed = true
        return verification
    }

    private struct WriterContext {
        var writer: AVAssetWriter
        var input: AVAssetWriterInput
        var adaptor: AVAssetWriterInputPixelBufferAdaptor
        var colorSpace: CGColorSpace
    }

    private static func makeWriterContext(manifest: SegmentJobManifest, quality: Double) throws -> WriterContext {
        let writer = try AVAssetWriter(outputURL: manifest.partialURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: manifest.canvasWidth,
                AVVideoHeightKey: manifest.canvasHeight,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: quality],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: manifest.canvasWidth,
                kCVPixelBufferHeightKey as String: manifest.canvasHeight,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else { throw StorageCoordinatorError.segmentWriterUnavailable }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? StorageCoordinatorError.segmentWriterUnavailable
        }
        writer.startSession(atSourceTime: mediaTime(manifest.frames[0]))
        return WriterContext(
            writer: writer,
            input: input,
            adaptor: adaptor,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
    }

    private static func append(
        _ frame: SegmentFrameInput,
        manifest: SegmentJobManifest,
        context: WriterContext
    ) async throws {
        try Task.checkCancellation()
        let image = try loadImage(frame.spoolURL)
        guard image.width <= manifest.canvasWidth, image.height <= manifest.canvasHeight else {
            context.writer.cancelWriting()
            throw StorageCoordinatorError.segmentVerificationFailed(
                "Frame \(frame.frameID) dimensions \(image.width)x\(image.height) exceed segment \(manifest.canvasWidth)x\(manifest.canvasHeight)"
            )
        }
        guard let pool = context.adaptor.pixelBufferPool else {
            throw StorageCoordinatorError.segmentWriterUnavailable
        }
        let pixelBuffer = try makePixelBuffer(pool: pool, manifest: manifest, image: image, colorSpace: context.colorSpace)
        while !context.input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard context.writer.status == .writing else {
                throw context.writer.error ?? StorageCoordinatorError.segmentWriterUnavailable
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard context.adaptor.append(pixelBuffer, withPresentationTime: mediaTime(frame)) else {
            throw context.writer.error ?? StorageCoordinatorError.segmentVerificationFailed(
                "AVAssetWriter rejected frame \(frame.frameID)"
            )
        }
    }

    private static func makePixelBuffer(
        pool: CVPixelBufferPool,
        manifest: SegmentJobManifest,
        image: CGImage,
        colorSpace: CGColorSpace
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else { throw StorageCoordinatorError.segmentWriterUnavailable }
        CVBufferSetAttachments(pixelBuffer, [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let drawingContext = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: manifest.canvasWidth,
            height: manifest.canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw StorageCoordinatorError.segmentWriterUnavailable }
        drawingContext.setFillColor(CGColor(gray: 0, alpha: 1))
        drawingContext.fill(CGRect(x: 0, y: 0, width: manifest.canvasWidth, height: manifest.canvasHeight))
        drawingContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixelBuffer
    }

    private static func validate(_ manifest: SegmentJobManifest) throws {
        guard !manifest.frames.isEmpty,
              manifest.canvasWidth > 0,
              manifest.canvasHeight > 0,
              manifest.canvasWidth.isMultiple(of: 2),
              manifest.canvasHeight.isMultiple(of: 2)
        else {
            throw StorageCoordinatorError.invalidSegmentManifest(manifest.jobID)
        }
        var previous: CMTime?
        var ids = Set<UUID>()
        for frame in manifest.frames {
            guard frame.ptsTimescale > 0, ids.insert(frame.frameID).inserted else {
                throw StorageCoordinatorError.invalidSegmentManifest(manifest.jobID)
            }
            let time = mediaTime(frame)
            if let previous, CMTimeCompare(previous, time) >= 0 {
                throw StorageCoordinatorError.invalidSegmentManifest(manifest.jobID)
            }
            previous = time
        }
    }

    static func verify(manifest: SegmentJobManifest, url: URL) async throws -> SegmentWriteVerification {
        try validate(manifest)
        let asset = AVURLAsset(url: url)
        let track = try await loadOnlyVideoTrack(asset)
        try await verifyDimensions(track: track, manifest: manifest)
        let sampleCount = try verifySamples(asset: asset, track: track, manifest: manifest)
        try await verifyBoundaryFrames(asset: asset, manifest: manifest)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else {
            throw StorageCoordinatorError.segmentVerificationFailed("Encoded segment is empty")
        }
        return SegmentWriteVerification(
            byteCount: size,
            sampleCount: sampleCount,
            canvasWidth: manifest.canvasWidth,
            canvasHeight: manifest.canvasHeight
        )
    }

    private static func loadOnlyVideoTrack(_ asset: AVURLAsset) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw StorageCoordinatorError.segmentVerificationFailed("Expected exactly one video track")
        }
        return track
    }

    private static func verifyDimensions(track: AVAssetTrack, manifest: SegmentJobManifest) async throws {
        let naturalSize = try await track.load(.naturalSize)
        guard Int(abs(naturalSize.width)) == manifest.canvasWidth,
              Int(abs(naturalSize.height)) == manifest.canvasHeight
        else {
            throw StorageCoordinatorError.segmentVerificationFailed(
                "Encoded dimensions \(naturalSize) do not match \(manifest.canvasWidth)x\(manifest.canvasHeight)"
            )
        }
    }

    private static func verifySamples(
        asset: AVURLAsset,
        track: AVAssetTrack,
        manifest: SegmentJobManifest
    ) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        guard reader.canAdd(output) else {
            throw StorageCoordinatorError.segmentVerificationFailed("Unable to inspect encoded samples")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? StorageCoordinatorError.segmentVerificationFailed("Unable to start sample verification")
        }
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            guard sampleCount < manifest.frames.count else {
                throw StorageCoordinatorError.segmentVerificationFailed("Encoded more samples than requested")
            }
            let expected = mediaTime(manifest.frames[sampleCount])
            let actual = CMSampleBufferGetPresentationTimeStamp(sample)
            guard CMTimeCompare(expected, actual) == 0 else {
                throw StorageCoordinatorError.segmentVerificationFailed(
                    "Sample \(sampleCount) PTS \(actual) does not equal \(expected)"
                )
            }
            sampleCount += 1
        }
        guard reader.status == .completed, sampleCount == manifest.frames.count else {
            throw reader.error ?? StorageCoordinatorError.segmentVerificationFailed(
                "Expected \(manifest.frames.count) samples, found \(sampleCount)"
            )
        }
        return sampleCount
    }

    private static func verifyBoundaryFrames(asset: AVURLAsset, manifest: SegmentJobManifest) async throws {
        var indices = [0]
        if manifest.frames.count > 2 { indices.append(manifest.frames.count / 2) }
        if manifest.frames.count > 1 { indices.append(manifest.frames.count - 1) }
        for index in indices {
            try await verifyBoundaryFrame(
                asset: asset,
                at: mediaTime(manifest.frames[index]),
                expectedWidth: manifest.canvasWidth,
                expectedHeight: manifest.canvasHeight
            )
        }
    }

    private static func verifyBoundaryFrame(
        asset: AVAsset,
        at time: CMTime,
        expectedWidth: Int,
        expectedHeight: Int
    ) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let (image, actualTime) = try await generator.image(at: time)
        guard CMTimeCompare(actualTime, time) == 0,
              image.width == expectedWidth,
              image.height == expectedHeight
        else {
            throw StorageCoordinatorError.segmentVerificationFailed("Boundary frame verification failed at \(time)")
        }
    }

    private static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else {
            throw StorageCoordinatorError.spoolSourceUnreadable(url)
        }
        return image
    }

    private static func mediaTime(_ frame: SegmentFrameInput) -> CMTime {
        CMTime(value: frame.ptsValue, timescale: frame.ptsTimescale)
    }
}
