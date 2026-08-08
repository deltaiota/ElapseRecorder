import ComposableArchitecture
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes one image at an exact presentation timestamp in an immutable video segment.
nonisolated struct VideoFrameExtractorClient {
    var imageAtTime: @Sendable (_ videoURL: URL, _ time: FramePresentationTime) async throws -> CGImage
    /// Writes a decoded frame to a temporary HEIC file for Quick Look.
    var temporaryImageFileAtTime: @Sendable (
        _ videoURL: URL,
        _ time: FramePresentationTime
    ) async throws -> URL
}

private nonisolated enum FrameExtractionError: Error {
    case encoderUnavailable
}

extension VideoFrameExtractorClient: DependencyKey {
    static let liveValue = Self(
        imageAtTime: { videoURL, time in
            try await FrameReader.shared.image(
                for: .videoFrame(video: videoURL, presentationTime: time)
            )
        },
        temporaryImageFileAtTime: { videoURL, time in
            let image = try await FrameReader.shared.image(
                for: .videoFrame(video: videoURL, presentationTime: time)
            )
            let url = FileManager.default.temporaryDirectory
                .appending(path: "elapse-ql-\(UUID().uuidString).heic")
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else { throw FrameExtractionError.encoderUnavailable }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else {
                throw FrameExtractionError.encoderUnavailable
            }
            return url
        }
    )

    static let testValue = Self(
        imageAtTime: { _, _ in
            reportIssue("VideoFrameExtractorClient.imageAtTime is unimplemented")
            throw FrameExtractionError.encoderUnavailable
        },
        temporaryImageFileAtTime: { _, _ in
            reportIssue("VideoFrameExtractorClient.temporaryImageFileAtTime is unimplemented")
            throw FrameExtractionError.encoderUnavailable
        }
    )
}

extension DependencyValues {
    var videoFrameExtractorClient: VideoFrameExtractorClient {
        get { self[VideoFrameExtractorClient.self] }
        set { self[VideoFrameExtractorClient.self] = newValue }
    }
}
