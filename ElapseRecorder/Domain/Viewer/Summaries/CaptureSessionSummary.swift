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
}
