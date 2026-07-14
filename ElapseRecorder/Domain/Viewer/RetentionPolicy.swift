import Foundation

/// Limits that bound how much capture history is kept. Any combination may be active; the
/// pruner deletes the oldest ended sessions first until every active limit is satisfied.
nonisolated struct RetentionPolicy: Equatable {
    /// Delete sessions that started longer ago than this.
    var maxAge: TimeInterval?
    /// Cap the total on-disk footprint; delete oldest sessions until under.
    var maxTotalBytes: Int?
    /// Cap the total number of screenshots kept; delete oldest sessions until under.
    var maxScreenshotCount: Int?

    static let none = Self(maxAge: nil, maxTotalBytes: nil, maxScreenshotCount: nil)

    var hasAnyLimit: Bool {
        maxAge != nil || maxTotalBytes != nil || maxScreenshotCount != nil
    }

    /// Given the ended sessions sorted oldest-first, returns the ids to delete so that every
    /// active limit holds. Deletes oldest first and stops as soon as the oldest remaining
    /// session is within the age limit and the size/count caps are satisfied. Open (still
    /// recording) sessions must not be included by the caller.
    func sessionIDsToPrune(endedSessionsOldestFirst sessions: [CaptureSessionSummary], now: Date) -> [UUID] {
        guard hasAnyLimit else { return [] }

        var totalBytes = sessions.reduce(0) { $0 + $1.sizeBytes }
        var totalCount = sessions.reduce(0) { $0 + $1.screenshotCount }
        let ageCutoff = maxAge.map { now.addingTimeInterval(-$0) }

        var ids: [UUID] = []
        for session in sessions {
            let tooOld = ageCutoff.map { session.startedAt < $0 } ?? false
            let overSize = maxTotalBytes.map { totalBytes > $0 } ?? false
            let overCount = maxScreenshotCount.map { totalCount > $0 } ?? false

            guard tooOld || overSize || overCount else { break }

            ids.append(session.id)
            totalBytes -= session.sizeBytes
            totalCount -= session.screenshotCount
        }
        return ids
    }
}
