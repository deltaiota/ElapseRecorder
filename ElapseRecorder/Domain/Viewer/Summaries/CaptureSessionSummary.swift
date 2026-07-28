import Foundation

nonisolated enum CaptureSessionStorageState: Equatable {
    case uncompacted
    case partiallyCompacted
    case compacted
}

nonisolated struct CaptureSessionSummary: Equatable, Identifiable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var startedAt: Date
    var endedAt: Date?
    var windowCount: Int
    var screenshotCount: Int
    var sizeBytes: Int = 0
    /// Number of this session's screenshots stored inside compacted video files.
    var compactedScreenshotCount: Int = 0

    var storageState: CaptureSessionStorageState {
        guard screenshotCount > 0, compactedScreenshotCount > 0 else { return .uncompacted }
        return compactedScreenshotCount == screenshotCount ? .compacted : .partiallyCompacted
    }

    var isCompacted: Bool {
        storageState == .compacted
    }
}
