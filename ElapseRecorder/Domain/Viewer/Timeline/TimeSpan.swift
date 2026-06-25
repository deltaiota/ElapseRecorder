import Foundation

/// A closed time interval on the session timeline (e.g. a stretch where no window was
/// capturable).
nonisolated struct TimeSpan: Equatable {
    var startedAt: Date
    var endedAt: Date
}
