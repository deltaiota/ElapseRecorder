import Foundation

nonisolated struct WindowCaptureSummary: Equatable, Identifiable {
    var id: UUID
    var displayNumber: Int
    var label: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var screenshotCount: Int
}
