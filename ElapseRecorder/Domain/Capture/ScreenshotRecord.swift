import Foundation

nonisolated struct ScreenshotRecord: Equatable, Identifiable {
    var id: UUID
    var windowID: UUID
    var sessionID: UUID
    var capturedAt: Date
    var fileURL: URL
    var fileSizeBytes: Int
}
