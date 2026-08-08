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

    /// Selects ended sessions for deletion while accounting for usage owned by active sessions.
    /// Active usage contributes to caps but can never itself be evicted.
    func sessionIDsToPrune(snapshot: RetentionSnapshot, now: Date) -> [UUID] {
        guard hasAnyLimit else { return [] }

        let sessions = snapshot.endedSessionsOldestFirst
        var totalBytes = snapshot.activeSizeBytes + sessions.reduce(0) { $0 + $1.sizeBytes }
        var totalCount = snapshot.activeFrameCount + sessions.reduce(0) { $0 + $1.screenshotCount }
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

    /// Compatibility helper for callers that already supply only ended-session usage.
    func sessionIDsToPrune(endedSessionsOldestFirst sessions: [CaptureSessionSummary], now: Date) -> [UUID] {
        sessionIDsToPrune(
            snapshot: RetentionSnapshot(
                endedSessionsOldestFirst: sessions,
                activeSizeBytes: 0,
                activeFrameCount: 0
            ),
            now: now
        )
    }
}
