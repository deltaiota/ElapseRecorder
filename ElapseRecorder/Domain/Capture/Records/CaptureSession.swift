import Foundation

nonisolated struct CaptureSession: Equatable, Identifiable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var processIdentifier: pid_t
    var startedAt: Date
    var endedAt: Date?
}
