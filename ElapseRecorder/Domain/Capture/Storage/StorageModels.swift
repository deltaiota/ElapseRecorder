import CoreGraphics
import Foundation

/// Correlates every capture callback with the exact recording generation that requested it.
nonisolated struct RecordingSessionHandle: Equatable, Hashable {
    var sessionID: UUID
    var bundleIdentifier: String
    var processIdentifier: pid_t
    var generation: UInt64
}

/// The stable window identity and display metadata captured alongside a frame.
nonisolated struct CapturedWindowMetadata: Equatable, Hashable {
    var windowID: UUID
    var systemWindowID: Int
    var displayNumber: Int
    var title: String?
}

/// CGImage is immutable. This wrapper makes that ownership guarantee explicit at the actor boundary.
nonisolated struct ImmutableCapturedImage: @unchecked Sendable {
    let cgImage: CGImage

    init(_ image: CGImage) {
        cgImage = image
    }

    init(_ image: CapturedImage) {
        cgImage = image.cgImage
    }
}

/// A completed capture with all correlation and timing data needed by durable storage.
nonisolated struct CapturedFrameEnvelope {
    var id: UUID
    var handle: RecordingSessionHandle
    var cycleSequence: Int64
    var scheduledOffsetNanoseconds: Int64
    var requestStartedAt: Date
    var completedAt: Date
    var window: CapturedWindowMetadata
    var image: ImmutableCapturedImage
    var encodingOptions: CaptureEncodingOptions
    var perceptualHash: UInt64

    init(
        id: UUID = UUID(),
        handle: RecordingSessionHandle,
        cycleSequence: Int64,
        scheduledOffsetNanoseconds: Int64,
        requestStartedAt: Date,
        completedAt: Date,
        window: CapturedWindowMetadata,
        image: ImmutableCapturedImage,
        encodingOptions: CaptureEncodingOptions,
        perceptualHash: UInt64 = 0
    ) {
        self.id = id
        self.handle = handle
        self.cycleSequence = cycleSequence
        self.scheduledOffsetNanoseconds = scheduledOffsetNanoseconds
        self.requestStartedAt = requestStartedAt
        self.completedAt = completedAt
        self.window = window
        self.image = image
        self.encodingOptions = encodingOptions
        self.perceptualHash = perceptualHash
    }
}

/// Durable intent written before the atomic spool file is published.
nonisolated struct SpoolFrameRegistration: Equatable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var windowID: UUID
    var bundleIdentifier: String
    var processIdentifier: pid_t
    var generation: UInt64
    var cycleSequence: Int64
    var scheduledOffsetNanoseconds: Int64
    var requestStartedAt: Date
    var completedAt: Date
    var spoolURL: URL
    var format: CaptureImageFormat
    var pixelWidth: Int
    var pixelHeight: Int
    var perceptualHash: UInt64
}

/// A spool registration whose atomic image publish has been durably acknowledged.
nonisolated struct StoredSpoolFrame: Equatable, Identifiable {
    var registration: SpoolFrameRegistration
    var byteCount: Int

    var id: UUID {
        registration.id
    }

    var sessionID: UUID {
        registration.sessionID
    }

    var windowID: UUID {
        registration.windowID
    }

    var bundleIdentifier: String {
        registration.bundleIdentifier
    }

    var processIdentifier: pid_t {
        registration.processIdentifier
    }

    var generation: UInt64 {
        registration.generation
    }

    var cycleSequence: Int64 {
        registration.cycleSequence
    }

    var scheduledOffsetNanoseconds: Int64 {
        registration.scheduledOffsetNanoseconds
    }

    var requestStartedAt: Date {
        registration.requestStartedAt
    }

    var completedAt: Date {
        registration.completedAt
    }

    var spoolURL: URL {
        registration.spoolURL
    }

    var format: CaptureImageFormat {
        registration.format
    }

    var pixelWidth: Int {
        registration.pixelWidth
    }

    var pixelHeight: Int {
        registration.pixelHeight
    }

    var perceptualHash: UInt64 {
        registration.perceptualHash
    }
}

nonisolated enum SpoolFrameState: String, Codable, Equatable {
    case registered
    case ready
    case failed
}

nonisolated struct SpoolFrameRecoveryItem: Equatable {
    var registration: SpoolFrameRegistration
    var state: SpoolFrameState
    var byteCount: Int?
}

/// Exact source identity and media time for one sample in an immutable segment.
nonisolated struct SegmentFrameInput: Equatable, Identifiable {
    var id: UUID {
        frameID
    }

    var frameID: UUID
    var spoolURL: URL
    var ptsValue: Int64
    var ptsTimescale: Int32
}

/// Durable job journal. It is persisted before the partial movie is created.
nonisolated struct SegmentJobManifest: Equatable, Identifiable {
    var id: UUID {
        jobID
    }

    var jobID: UUID
    var assetID: UUID
    var handle: RecordingSessionHandle
    var sessionID: UUID {
        handle.sessionID
    }

    var windowID: UUID
    var partialURL: URL
    var finalURL: URL
    var canvasWidth: Int
    var canvasHeight: Int
    var frames: [SegmentFrameInput]
    var createdAt: Date
}

nonisolated struct SegmentJobLease: Equatable {
    var manifest: SegmentJobManifest
    var workerID: UUID
    var expiresAt: Date
}

nonisolated struct SegmentJobCommit: Equatable {
    var jobID: UUID
    var workerID: UUID
    var assetID: UUID
    var finalURL: URL
    var byteCount: Int
    var frameCount: Int
    var canvasWidth: Int
    var canvasHeight: Int
}

nonisolated struct SegmentCleanupManifest: Equatable {
    var jobID: UUID
    var spoolURLs: [URL]
}

nonisolated enum SegmentJobState: String, Codable, Equatable {
    case queued
    case leased
    case failed
    case published
    case committed
}

nonisolated struct SegmentRecoveryItem: Equatable {
    var manifest: SegmentJobManifest
    var state: SegmentJobState
    var workerID: UUID?
}

nonisolated struct SegmentWriteVerification: Equatable {
    var byteCount: Int
    var sampleCount: Int
    var canvasWidth: Int
    var canvasHeight: Int
}

/// Every dimension is a hard upper bound. Reaching any one seals the current segment.
nonisolated struct SegmentTarget: Equatable {
    var maximumFrames: Int
    var maximumDuration: TimeInterval
    var maximumBytes: Int

    static let defaultValue = Self(
        maximumFrames: 120,
        maximumDuration: 5 * 60,
        maximumBytes: 256 * 1024 * 1024
    )

    init(maximumFrames: Int, maximumDuration: TimeInterval, maximumBytes: Int) {
        precondition(maximumFrames > 0)
        precondition(maximumDuration > 0)
        precondition(maximumBytes > 0)
        self.maximumFrames = maximumFrames
        self.maximumDuration = maximumDuration
        self.maximumBytes = maximumBytes
    }
}

nonisolated struct StorageCoordinatorConfiguration: Equatable {
    var queueCapacity: Int
    var maximumSpoolBytes: Int
    var minimumFreeDiskBytes: Int64
    var segmentTarget: SegmentTarget
    var mediaTimescale: Int32
    var leaseDuration: TimeInterval
    var recoveryBatchSize: Int

    static let defaultValue = Self(
        queueCapacity: 8,
        maximumSpoolBytes: 2 * 1024 * 1024 * 1024,
        minimumFreeDiskBytes: 512 * 1024 * 1024,
        segmentTarget: .defaultValue,
        mediaTimescale: 30,
        leaseDuration: 5 * 60,
        recoveryBatchSize: 512
    )

    init(
        queueCapacity: Int,
        maximumSpoolBytes: Int,
        minimumFreeDiskBytes: Int64,
        segmentTarget: SegmentTarget,
        mediaTimescale: Int32,
        leaseDuration: TimeInterval,
        recoveryBatchSize: Int
    ) {
        precondition(queueCapacity > 0)
        precondition(maximumSpoolBytes > 0)
        precondition(minimumFreeDiskBytes >= 0)
        precondition(mediaTimescale > 0)
        precondition(leaseDuration > 0)
        precondition(recoveryBatchSize > 0)
        self.queueCapacity = queueCapacity
        self.maximumSpoolBytes = maximumSpoolBytes
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
        self.segmentTarget = segmentTarget
        self.mediaTimescale = mediaTimescale
        self.leaseDuration = leaseDuration
        self.recoveryBatchSize = recoveryBatchSize
    }
}

nonisolated enum StorageEnqueueResult: Equatable {
    case accepted(frameID: UUID)
    case backpressured(capacity: Int)
}

nonisolated enum StorageDegradation: Equatable, Hashable {
    case queueFull(capacity: Int)
    case spoolWriteFailed(frameID: UUID, message: String)
    case metadataCommitFailed(frameID: UUID, message: String)
    case segmentFailed(jobID: UUID, message: String)
    case recoveryFailed(message: String)
    case spoolCapacityExceeded(maximumBytes: Int)
    case insufficientFreeSpace(requiredBytes: Int64, availableBytes: Int64)
    case maintenanceInProgress
}

nonisolated enum StorageCoordinatorEvent: Equatable {
    /// The atomic spool and its metadata row are durable; the image is now viewer-safe.
    case frameCommitted(StoredSpoolFrame)
    case segmentCommitted(handle: RecordingSessionHandle, assetID: UUID, frameIDs: [UUID], url: URL)
    case storageDegraded(StorageDegradation)
    case storageResumed
}

nonisolated struct StorageMaintenanceLease: Equatable, Hashable {
    var id: UUID
}

nonisolated enum StorageCoordinatorError: Error, Equatable {
    case sessionFlushFailed(UUID)
    case invalidSegmentManifest(UUID)
    case readyAssetAlreadyExists(URL)
    case segmentWriterUnavailable
    case spoolSourceUnreadable(URL)
    case segmentVerificationFailed(String)
    case maintenanceLeaseInvalid
}
