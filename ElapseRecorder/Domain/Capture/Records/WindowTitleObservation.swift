import Foundation

/// A window's title as observed at a point in time. Windows keep an ordered history of
/// these so a mid-session rename (e.g. "Untitled" saved to "Notes.txt") is recorded rather
/// than discarded; the window keeps its stable identity while its title evolves.
nonisolated struct WindowTitleObservation: Equatable, Identifiable {
    var id: UUID
    var title: String?
    var observedAt: Date
}
