import Foundation

/// The outcome of a storage compaction pass: how many window videos were produced and how much
/// disk space was reclaimed by replacing standalone frames with compacted HEVC videos.
nonisolated struct StorageCompactionResult: Equatable {
    var compactedWindowCount: Int
    var framesCompacted: Int
    var bytesBefore: Int
    var bytesAfter: Int

    static let empty = Self(compactedWindowCount: 0, framesCompacted: 0, bytesBefore: 0, bytesAfter: 0)

    var isEmpty: Bool {
        compactedWindowCount == 0
    }

    var bytesSaved: Int {
        max(0, bytesBefore - bytesAfter)
    }
}
