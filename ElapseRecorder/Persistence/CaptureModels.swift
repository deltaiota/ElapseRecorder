import Foundation

/// Explicit lifecycle states persisted by the V2 SQLite schema.
nonisolated enum CaptureSessionDatabaseState: String {
    case open
    case closed
    case tombstoned
}

nonisolated enum MediaAssetKind: String {
    case spoolImage
    case videoSegment
}

nonisolated enum MediaAssetState: String {
    case writing
    case ready
    case failed
}

nonisolated enum PersistenceStoreError: Error, Equatable {
    case sessionNotFound(UUID)
    case windowNotFound(UUID)
    case invalidSpoolMetadata(UUID)
    case frameNotFound(UUID)
    case segmentJobNotFound(UUID)
    case segmentJobNotLeased(UUID)
    case segmentLeaseOwnedByAnotherWorker(UUID)
    case segmentCommitMismatch(UUID)
    case invalidSegmentManifest(UUID)
    case readyAssetAlreadyExists(String)
}

nonisolated enum CaptureDatabaseSchema {
    static let migrationV1 = "create-backend-v2"
    static let migrationV2 = "add-segment-cleanup-state"
    static let migrationV3 = "add-backend-import-marker"
    static let fileName = "ElapseRecorder-v2.sqlite"
}
