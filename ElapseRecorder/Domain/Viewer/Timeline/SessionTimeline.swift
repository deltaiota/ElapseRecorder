import Foundation

/// A derived, viewer-facing view of one session's window lifecycle: each window as a lane
/// with its title segments, plus the spans where nothing was capturable. Feeds the timeline
/// graph that sits between session selection and the screenshot grid.
nonisolated struct SessionTimeline: Equatable {
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date?
    var lanes: [WindowLane]
    var unavailableSpans: [TimeSpan]
}
