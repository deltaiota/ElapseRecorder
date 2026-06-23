import Foundation

nonisolated struct MonitoredWindow: Equatable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var systemWindowID: Int
    var displayNumber: Int
    var label: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
}
