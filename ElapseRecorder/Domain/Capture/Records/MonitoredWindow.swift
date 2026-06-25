import Foundation

nonisolated struct MonitoredWindow: Equatable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var systemWindowID: Int
    var displayNumber: Int
    var label: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    /// Ordered title observations for this window, oldest first. The first entry is the
    /// title at first sighting (mirrored by `label`); later entries record renames.
    var titleHistory: [WindowTitleObservation] = []

    /// The most recently observed title, falling back to the first-seen `label`.
    var currentTitle: String? {
        titleHistory.last?.title ?? label
    }
}
