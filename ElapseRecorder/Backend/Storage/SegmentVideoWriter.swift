import AVFoundation
import ComposableArchitecture
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// Writes and exactly verifies one journaled HEVC segment. The caller owns publish and DB commit.
nonisolated struct SegmentVideoWriterClient {
    var writeAndVerify: @Sendable (_ manifest: SegmentJobManifest, _ quality: Double) async throws -> SegmentWriteVerification
    var verifyPublished: @Sendable (_ manifest: SegmentJobManifest) async throws -> SegmentWriteVerification
}

extension SegmentVideoWriterClient: DependencyKey {
    static let liveValue = Self(
        writeAndVerify: { manifest, quality in
            try await SegmentVideoWriter.writeAndVerify(manifest: manifest, quality: quality)
        },
        verifyPublished: { manifest in
            try await SegmentVideoWriter.verify(manifest: manifest, url: manifest.finalURL)
        }
    )

    static let testValue = Self(
        writeAndVerify: { manifest, _ in
            throw StorageCoordinatorError.segmentVerificationFailed("Unimplemented segment writer for \(manifest.jobID)")
        },
        verifyPublished: { manifest in
            throw StorageCoordinatorError.segmentVerificationFailed("Unimplemented segment verifier for \(manifest.jobID)")
        }
    )
}

extension DependencyValues {
    var segmentVideoWriterClient: SegmentVideoWriterClient {
        get { self[SegmentVideoWriterClient.self] }
        set { self[SegmentVideoWriterClient.self] = newValue }
    }
}

private nonisolated enum SegmentVideoWriter {
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

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let settings: [String: Any] = [
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
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
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
        guard writer.canAdd(input) else {
            throw StorageCoordinatorError.segmentWriterUnavailable
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? StorageCoordinatorError.segmentWriterUnavailable
        }
        let firstTime = mediaTime(manifest.frames[0])
        writer.startSession(atSourceTime: firstTime)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        for frame in manifest.frames {
            try Task.checkCancellation()
            let image = try loadImage(frame.spoolURL)
            guard image.width <= manifest.canvasWidth, image.height <= manifest.canvasHeight else {
                writer.cancelWriting()
                throw StorageCoordinatorError.segmentVerificationFailed(
                    "Frame \(frame.frameID) dimensions \(image.width)x\(image.height) exceed segment \(manifest.canvasWidth)x\(manifest.canvasHeight)"
                )
            }
            guard let pool = adaptor.pixelBufferPool else {
                writer.cancelWriting()
                throw StorageCoordinatorError.segmentWriterUnavailable
            }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer
            else {
                writer.cancelWriting()
                throw StorageCoordinatorError.segmentWriterUnavailable
            }

            CVBufferSetAttachments(pixelBuffer, [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ] as CFDictionary, .shouldPropagate)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: manifest.canvasWidth,
                height: manifest.canvasHeight,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                writer.cancelWriting()
                throw StorageCoordinatorError.segmentWriterUnavailable
            }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: manifest.canvasWidth, height: manifest.canvasHeight))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else {
                    throw writer.error ?? StorageCoordinatorError.segmentWriterUnavailable
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard writer.status == .writing else {
                throw writer.error ?? StorageCoordinatorError.segmentWriterUnavailable
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: mediaTime(frame)) else {
                input.markAsFinished()
                writer.cancelWriting()
                throw writer.error ?? StorageCoordinatorError.segmentVerificationFailed(
                    "AVAssetWriter rejected frame \(frame.frameID)"
                )
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? StorageCoordinatorError.segmentWriterUnavailable
        }

        let verification = try await verify(manifest: manifest, url: outputURL)
        completed = true
        return verification
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
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw StorageCoordinatorError.segmentVerificationFailed("Expected exactly one video track")
        }
        let naturalSize = try await track.load(.naturalSize)
        guard Int(abs(naturalSize.width)) == manifest.canvasWidth,
              Int(abs(naturalSize.height)) == manifest.canvasHeight
        else {
            throw StorageCoordinatorError.segmentVerificationFailed(
                "Encoded dimensions \(naturalSize) do not match \(manifest.canvasWidth)x\(manifest.canvasHeight)"
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
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

        try await verifyBoundaryFrame(
            asset: asset,
            at: mediaTime(manifest.frames[0]),
            expectedWidth: manifest.canvasWidth,
            expectedHeight: manifest.canvasHeight
        )
        if manifest.frames.count > 2 {
            let middle = manifest.frames.count / 2
            try await verifyBoundaryFrame(
                asset: asset,
                at: mediaTime(manifest.frames[middle]),
                expectedWidth: manifest.canvasWidth,
                expectedHeight: manifest.canvasHeight
            )
        }
        if manifest.frames.count > 1 {
            try await verifyBoundaryFrame(
                asset: asset,
                at: mediaTime(manifest.frames[manifest.frames.count - 1]),
                expectedWidth: manifest.canvasWidth,
                expectedHeight: manifest.canvasHeight
            )
        }

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
