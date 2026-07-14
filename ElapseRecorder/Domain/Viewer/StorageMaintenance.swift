import Foundation

/// A stored screenshot's identity and on-disk location, used by the storage integrity sweep to
/// reconcile database records against files on disk.
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
