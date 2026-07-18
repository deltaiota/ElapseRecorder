import Foundation

nonisolated struct AppCaptureSummary: Equatable, Identifiable {
    var id: String {
        bundleIdentifier
    }

    var bundleIdentifier: String
    var displayName: String
    var sessionCount: Int
    var screenshotCount: Int
    var lastCapturedAt: Date?
    var sizeBytes: Int = 0
    /// Total recorded time across all of this app's sessions (sum of each session's
    /// start→end span). Zero when the app has no sessions yet, so the UI can hide it.
    var totalActiveDuration: TimeInterval = 0
}
