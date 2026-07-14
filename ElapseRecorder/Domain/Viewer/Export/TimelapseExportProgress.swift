import Foundation

/// A progress update streamed from the timelapse encoder while it writes frames.
nonisolated struct TimelapseExportProgress: Equatable {
    var emittedFrames: Int
    var totalFrames: Int

    var fraction: Double {
        guard totalFrames > 0 else { return 0 }
        return min(1, Double(emittedFrames) / Double(totalFrames))
    }
}

/// The live status of an in-flight timelapse export, used to drive the progress sheet. Bundles
/// the chosen technical options with running counts so the UI can show percentage, frame
/// progress, format details, and an estimated time remaining.
nonisolated struct TimelapseExportStatus: Equatable {
    var options: ExportOptions
    var totalFrames: Int
    var emittedFrames: Int
    var startedAt: Date

    var fraction: Double {
        guard totalFrames > 0 else { return 0 }
        return min(1, Double(emittedFrames) / Double(totalFrames))
    }

    /// Estimates the time left by extrapolating the average time-per-frame observed so far.
    /// Returns nil until at least one frame has been emitted (no rate yet) or once finished.
    func estimatedTimeRemaining(asOf now: Date) -> Duration? {
        guard emittedFrames > 0, emittedFrames < totalFrames else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed > 0 else { return nil }
        let secondsPerFrame = elapsed / Double(emittedFrames)
        let remaining = secondsPerFrame * Double(totalFrames - emittedFrames)
        return .seconds(remaining)
    }
}
