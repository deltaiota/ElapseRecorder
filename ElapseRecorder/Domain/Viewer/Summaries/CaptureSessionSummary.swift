import Foundation

nonisolated struct CaptureSessionSummary: Equatable, Identifiable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var startedAt: Date
    var endedAt: Date?
    var windowCount: Int
    var screenshotCount: Int
    var sizeBytes: Int = 0
    /// Number of this session's screenshots stored inside a compacted video. Drives the
    /// compacted-vs-uncompressed session icon in the list.
    var compactedScreenshotCount: Int = 0

    /// True once the session has been compacted into HEVC video(s).
    var isCompacted: Bool {
        compactedScreenshotCount > 0
    }
}
