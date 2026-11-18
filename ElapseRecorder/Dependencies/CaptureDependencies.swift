@preconcurrency import AppKit
import ApplicationServices
import AVFoundation
import Chronicle
import ComposableArchitecture
import CoreGraphics
import Defaults
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

nonisolated extension CaptureImageFormat: Defaults.Serializable {}

nonisolated extension Defaults.Keys {
    static let captureImageFormat = Key<CaptureImageFormat>("captureImageFormat", default: .heic)
    static let captureHEICQuality = Key<Double>("captureHEICQuality", default: 0.82)
    static let segmentHEVCQuality = Key<Double>("segmentHEVCQuality", default: 0.65)
    /// Longest-edge pixel cap applied to captured frames (0 = native resolution). Retina windows
    /// are captured at physical resolution, so capping keeps frames review-crisp while cutting
    /// storage roughly by the square of the scale factor.
    static let captureMaxDimension = Key<Int>("captureMaxDimension", default: 2560)
    static let thumbnailMaximumPixelSize = Key<Int>("thumbnailMaximumPixelSize", default: 1024)
    static let whitelistedAppConfigsData = Key<Data>("whitelistedAppConfigsData", default: Data())
    static let customCaptureRootPath = Key<String>("customCaptureRootPath", default: "")
    static let retentionMaxAgeEnabled = Key<Bool>("retentionMaxAgeEnabled", default: false)
    static let retentionMaxAgeDays = Key<Int>("retentionMaxAgeDays", default: 30)
    static let retentionMaxSizeEnabled = Key<Bool>("retentionMaxSizeEnabled", default: false)
    static let retentionMaxSizeMegabytes = Key<Int>("retentionMaxSizeMegabytes", default: 2048)
    static let retentionMaxCountEnabled = Key<Bool>("retentionMaxCountEnabled", default: false)
    static let retentionMaxScreenshotCount = Key<Int>("retentionMaxScreenshotCount", default: 10000)
}

nonisolated struct DateClient {
    var now: @Sendable () -> Date
}

nonisolated struct IDGeneratorClient {
    var uuid: @Sendable () -> UUID
}

nonisolated struct CapturePreferencesClient {
    var encodingOptions: @Sendable () -> CaptureEncodingOptions
    var segmentHEVCQuality: @Sendable () -> Double
    var thumbnailMaximumPixelSize: @Sendable () -> Int
    var retentionPolicy: @Sendable () -> RetentionPolicy
}

/// Computes a 64-bit difference hash (dHash) of a captured frame for near-duplicate detection.
nonisolated struct PerceptualHashClient {
    var hash: @Sendable (_ image: CapturedImage) -> UInt64
}

nonisolated struct WhitelistConfigurationClient {
    var load: @Sendable () async throws -> [WhitelistedAppConfig]
    var save: @Sendable (_ configs: [WhitelistedAppConfig]) async throws -> Void
}

nonisolated struct WorkspaceClient {
    var runningApplications: @Sendable () async -> [RunningApplication]
    var events: @Sendable () -> AsyncStream<WorkspaceEvent>
    var frontmostApplication: @Sendable () async -> RunningApplication?
}

nonisolated struct CapturePermissionClient {
    var status: @Sendable () async -> CapturePermissionStatus
    var request: @Sendable () async -> CapturePermissionStatus
}

nonisolated struct ScreenCaptureClient {
    var windows: @Sendable (_ application: RunningApplication) async throws -> [CapturableWindow]
    var capture: @Sendable (_ windowID: Int, _ minimumFrameInterval: TimeInterval) async throws -> CapturedImage
    var release: @Sendable (_ processIdentifier: pid_t) async -> Void
}

nonisolated struct ImageEncodingClient {
    var encode: @Sendable (_ image: CapturedImage, _ options: CaptureEncodingOptions) async throws -> Data
}

nonisolated struct FileStorageClient {
    var captureRoot: @Sendable () throws -> URL
    var screenshotURL: @Sendable (_ session: CaptureSession, _ window: MonitoredWindow, _ capturedAt: Date, _ format: CaptureImageFormat) throws -> URL
    var write: @Sendable (_ data: Data, _ url: URL) async throws -> Int
    var deleteSessionCaptures: @Sendable (_ bundleIdentifier: String, _ sessionID: UUID) async throws -> Void
    var deleteAppCaptures: @Sendable (_ bundleIdentifier: String) async throws -> Void
    /// Unique durable spool location for a frame. Callers must never reuse a frame UUID.
    var spoolFrameURL: @Sendable (_ handle: RecordingSessionHandle, _ windowID: UUID, _ frameID: UUID, _ format: CaptureImageFormat) throws -> URL
    /// Unique staging and immutable ready locations for a segment asset.
    var segmentAssetURLs: @Sendable (_ handle: RecordingSessionHandle, _ assetID: UUID) throws -> (partial: URL, final: URL)
    /// Atomically publishes a staged segment without replacing an existing ready asset.
    var publishSegment: @Sendable (_ partialURL: URL, _ finalURL: URL) async throws -> Void
    var fileExists: @Sendable (_ url: URL) async -> Bool
    var fileSize: @Sendable (_ url: URL) async throws -> Int
    var availableCapacity: @Sendable () async throws -> Int64
    var probeWritable: @Sendable () async throws -> Void
    /// All regular files under the capture root(s), used by the integrity sweep to find orphans.
    var captureFileURLs: @Sendable () async throws -> [URL]
    /// Of the given absolute paths, those that still exist on disk (root-agnostic existence
    /// check so records written under a previous capture location aren't wrongly pruned).
    var filterExistingPaths: @Sendable (_ paths: [String]) async -> Set<String>
    /// Deletes the given files (ignoring any that are already gone) and returns bytes reclaimed.
    var removeFiles: @Sendable (_ urls: [URL]) async throws -> Int
    /// Tombstone deletion: ignores only missing files and surfaces every other failure for retry.
    var removeFilesStrict: @Sendable (_ urls: [URL]) async throws -> Int
}

nonisolated struct PersistenceClient {
    var openSession: @Sendable (_ session: CaptureSession) async throws -> Void
    var closeSession: @Sendable (_ sessionID: UUID, _ endedAt: Date) async throws -> Void
    var closeOpenSessions: @Sendable (_ endedAt: Date) async throws -> Int
    var deleteSession: @Sendable (_ sessionID: UUID) async throws -> Void
    var deleteApp: @Sendable (_ bundleIdentifier: String) async throws -> Void
    var deleteScreenshots: @Sendable (_ ids: [UUID]) async throws -> Void
    var screenshotFileIndex: @Sendable () async throws -> [ScreenshotFileReference]
    var sessionsStartedBefore: @Sendable (_ cutoff: Date, _ bundleIdentifier: String?) async throws -> [CaptureSessionSummary]
    var screenshotPathsForSession: @Sendable (_ sessionID: UUID) async throws -> [String]
    var screenshotPathsForApp: @Sendable (_ bundleIdentifier: String) async throws -> [String]
    var endedSessionsOldestFirst: @Sendable () async throws -> [CaptureSessionSummary]
    /// Consistent totals: ended sessions are eviction candidates; open-session usage is counted
    /// against limits but is never returned as a candidate.
    var retentionSnapshot: @Sendable () async throws -> RetentionSnapshot
    /// Atomically tombstones eligible ended sessions and journals their unique referenced files.
    var prepareSessionDeletion: @Sendable (_ sessionIDs: [UUID]) async throws -> StorageDeletionManifest?
    var pendingSessionDeletions: @Sendable () async throws -> [StorageDeletionManifest]
    /// Atomically removes tombstoned metadata after its files have been removed.
    var finalizeSessionDeletion: @Sendable (_ tombstoneID: UUID) async throws -> Void
    var upsertWindow: @Sendable (_ window: MonitoredWindow) async throws -> Void
    var recordScreenshot: @Sendable (_ record: ScreenshotRecord) async throws -> Void
    var recordCaptureUnavailable: @Sendable (_ record: CaptureUnavailableRecord) async throws -> Void
    var registerSpoolFrame: @Sendable (_ registration: SpoolFrameRegistration) async throws -> Void
    var markSpoolFrameReady: @Sendable (_ frameID: UUID, _ byteCount: Int) async throws -> StoredSpoolFrame
    var failSpoolFrame: @Sendable (_ frameID: UUID, _ message: String) async throws -> Void
    var recoverSpoolFrames: @Sendable (_ limit: Int) async throws -> [SpoolFrameRecoveryItem]
    var pendingSpoolFrames: @Sendable (_ limit: Int) async throws -> [StoredSpoolFrame]
    var spoolByteCount: @Sendable () async throws -> Int
    var createSegmentJob: @Sendable (_ manifest: SegmentJobManifest) async throws -> Void
    var leaseSegmentJob: @Sendable (_ workerID: UUID, _ now: Date, _ leaseDuration: TimeInterval) async throws -> SegmentJobLease?
    var markSegmentJobPublished: @Sendable (_ publication: SegmentJobCommit) async throws -> Void
    var commitSegmentJob: @Sendable (_ commit: SegmentJobCommit) async throws -> [URL]
    var failSegmentJob: @Sendable (
        _ jobID: UUID,
        _ workerID: UUID,
        _ message: String,
        _ retryAt: Date,
        _ finalByteCount: Int
    ) async throws -> Void
    var requeueSegmentJob: @Sendable (_ jobID: UUID, _ workerID: UUID) async throws -> Void
    var recoverSegmentJobs: @Sendable (_ now: Date) async throws -> [SegmentRecoveryItem]
    var pendingSegmentCleanups: @Sendable () async throws -> [SegmentCleanupManifest]
    var completeSegmentCleanup: @Sendable (_ jobID: UUID) async throws -> Void
    var apps: @Sendable () async throws -> [AppCaptureSummary]
    var sessions: @Sendable (_ bundleIdentifier: String) async throws -> [CaptureSessionSummary]
    var windows: @Sendable (_ sessionID: UUID) async throws -> [WindowCaptureSummary]
    var screenshotsForSession: @Sendable (_ sessionID: UUID) async throws -> [ScreenshotRecord]
    var screenshotsForWindow: @Sendable (_ windowID: UUID) async throws -> [ScreenshotRecord]
    var screenshotsForApp: @Sendable (_ bundleIdentifier: String) async throws -> [ScreenshotRecord]
    /// A stable, bounded keyset page in chronological `(capturedAt, id)` order.
    var framePage: @Sendable (_ query: FrameQuery, _ after: FrameCursor?, _ limit: Int) async throws -> FramePage
    /// Count for the complete descriptor, independent of the current presentation page.
    /// Freezes a query at its current inclusive terminal keyset coordinate in one read transaction.
    var frameQuerySnapshot: @Sendable (_ query: FrameQuery) async throws -> FrameQuerySnapshot
    var frameCount: @Sendable (_ query: FrameQuery) async throws -> Int
    /// Resolves an explicit selection in the same order as `ids`; unknown ids are omitted.
    var framesByID: @Sendable (_ ids: [UUID]) async throws -> [ScreenshotRecord]
    var timelineForSession: @Sendable (_ sessionID: UUID) async throws -> [CaptureTimelineEntry]
    var timelineForWindow: @Sendable (_ sessionID: UUID, _ windowID: UUID) async throws -> [CaptureTimelineEntry]
    var timelineForApp: @Sendable (_ bundleIdentifier: String) async throws -> [CaptureTimelineEntry]
    var sessionTimeline: @Sendable (_ sessionID: UUID) async throws -> SessionTimeline
}

nonisolated struct ThumbnailClient {
    var thumbnail: @Sendable (_ source: FrameSource, _ maximumPixelSize: Int) async throws -> CGImage
}

nonisolated struct ImageLoadingClient {
    var fullSizeImage: @Sendable (_ url: URL) async throws -> CGImage
}

nonisolated struct FileRevealClient {
    var reveal: @Sendable (_ url: URL) async -> Void
}

nonisolated struct LoggingClient {
    var log: @Sendable (_ level: LogLevel, _ message: String, _ metadata: [String: LogMetadataValue]) -> Void
}
