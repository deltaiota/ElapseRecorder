import Foundation

nonisolated struct CaptureUnavailableRecord: Equatable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date
    var reason: CaptureUnavailableReason
}
