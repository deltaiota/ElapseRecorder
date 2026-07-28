import Foundation

/// Real capture cadence derived from per-frame timestamps. Compaction changes only the pixel
/// source; every `ScreenshotRecord.capturedAt` remains authoritative.
nonisolated enum ScreenshotInterval {
    private struct WindowRun: Hashable {
        var sessionID: UUID
        var windowID: UUID
    }

    /// Average of consecutive intervals within each session-scoped window. Cross-session and
    /// cross-window gaps are excluded so a flat gallery does not count overnight downtime.
    static func average(records: [ScreenshotRecord]) -> TimeInterval? {
        let groups = Dictionary(grouping: records) {
            WindowRun(sessionID: $0.sessionID, windowID: $0.windowID)
        }
        var total: TimeInterval = 0
        var intervalCount = 0

        for group in groups.values {
            let timestamps = group.map(\.capturedAt).sorted()
            for (earlier, later) in zip(timestamps, timestamps.dropFirst()) {
                total += later.timeIntervalSince(earlier)
                intervalCount += 1
            }
        }

        return intervalCount > 0 ? total / Double(intervalCount) : nil
    }
}
