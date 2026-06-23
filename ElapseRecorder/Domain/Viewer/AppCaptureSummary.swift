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
}
