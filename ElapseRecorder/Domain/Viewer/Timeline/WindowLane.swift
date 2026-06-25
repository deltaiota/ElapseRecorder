import Foundation

/// One window's lane on the session timeline: a stable window (by id) drawn across time
/// from when it was first seen to last seen, divided into constant-title segments.
nonisolated struct WindowLane: Equatable, Identifiable {
    var windowID: UUID
    var displayNumber: Int
    var systemWindowID: Int
    var bornAt: Date
    var diedAt: Date
    var segments: [WindowTitleSegment]
    var screenshotCount: Int

    var id: UUID {
        windowID
    }
}
