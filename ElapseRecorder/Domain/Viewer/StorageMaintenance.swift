import Foundation

/// One stored media asset's identity and on-disk location, used by the storage integrity sweep.
/// Segment assets appear once even though many frame records reference the same immutable file.
nonisolated struct ScreenshotFileReference: Equatable {
    var id: UUID
    var path: String
    var sizeBytes: Int
}

/// The result of a storage integrity sweep: records removed because their file was missing, and
/// orphan files removed because no record referenced them.
nonisolated struct StorageIntegrityResult: Equatable {
    var removedRecordCount: Int
    var removedFileCount: Int
    var reclaimedBytes: Int

    static let empty = Self(removedRecordCount: 0, removedFileCount: 0, reclaimedBytes: 0)

    var isEmpty: Bool {
        removedRecordCount == 0 && removedFileCount == 0
    }
}

/// One consistent retention accounting snapshot. Open-session usage contributes to global caps,
/// while only the ended sessions are eligible for eviction.
nonisolated struct RetentionSnapshot: Equatable {
    let endedSessionsOldestFirst: [CaptureSessionSummary]
    let activeSizeBytes: Int
    let activeFrameCount: Int

    init(
        endedSessionsOldestFirst: [CaptureSessionSummary],
        activeSizeBytes: Int,
        activeFrameCount: Int
    ) {
        self.endedSessionsOldestFirst = endedSessionsOldestFirst
        self.activeSizeBytes = max(0, activeSizeBytes)
        self.activeFrameCount = max(0, activeFrameCount)
    }
}

nonisolated struct StorageDeletionSession: Equatable {
    let id: UUID
    let bundleIdentifier: String
}

/// Durable deletion journal prepared in the same transaction that tombstones its sessions.
/// Every URL is unique even when many frames reference one immutable video asset.
nonisolated struct StorageDeletionManifest: Equatable, Identifiable {
    let id: UUID
    let sessions: [StorageDeletionSession]
    let fileURLs: [URL]

    init(id: UUID, sessions: [StorageDeletionSession], fileURLs: [URL]) {
        self.id = id
        self.sessions = sessions
        self.fileURLs = Array(Set(fileURLs)).sorted { $0.path < $1.path }
    }
}
