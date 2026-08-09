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
            try await SegmentVideoWriterImplementation.writeAndVerify(manifest: manifest, quality: quality)
        },
        verifyPublished: { manifest in
            try await SegmentVideoWriterImplementation.verify(manifest: manifest, url: manifest.finalURL)
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
