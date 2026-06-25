import Foundation

/// A span of a window's life during which its title stayed constant — a node on the
/// timeline lane that the user can click to open that title's screenshots.
nonisolated struct WindowTitleSegment: Equatable, Identifiable {
    /// The id of the title observation that started this segment.
    var id: UUID
    var title: String?
    var startedAt: Date
    var endedAt: Date
    var screenshotCount: Int
}
