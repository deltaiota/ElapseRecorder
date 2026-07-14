import Foundation

/// A single standalone frame that is a candidate for compaction into a window video.
nonisolated struct CompactableFrame: Equatable, Identifiable {
    var id: UUID
    var sourceURL: URL
    var pixelWidth: Int
    var pixelHeight: Int
    var capturedAt: Date
}

/// The plan for compacting one window's standalone frames into a single HEVC video.
nonisolated struct WindowCompactionPlan: Equatable, Identifiable {
    var id: UUID {
        windowID
    }

    var windowID: UUID
    var displayNumber: Int
    var outputURL: URL
    /// Canvas dimensions for the video. Zero means "derive from the first decoded frame"
    /// (used when frames predate dimension tracking).
    var canvasWidth: Int
    var canvasHeight: Int
    /// Frames in presentation order; the array index is the video frame index.
    var frames: [CompactableFrame]
}

/// The plan for compacting all eligible windows of one closed session.
nonisolated struct SessionCompactionPlan: Equatable {
    var sessionID: UUID
    var windows: [WindowCompactionPlan]

    var isEmpty: Bool {
        windows.isEmpty
    }

    var totalFrameCount: Int {
        windows.reduce(0) { $0 + $1.frames.count }
    }
}

/// Pure planning for video compaction. Decides which windows/frames to roll into videos and
/// how large each video canvas should be, without touching SwiftData or the filesystem.
nonisolated enum CompactionPlanner {
    /// Windows with fewer standalone frames than this are left as individual files (a video
    /// wrapper would not save meaningful space and adds random-access cost).
    static let minimumFramesPerWindow = 8

    struct WindowInput: Equatable {
        var windowID: UUID
        var displayNumber: Int
        /// Only standalone (not-yet-compacted) frames for the window.
        var frames: [CompactableFrame]
    }

    static func plan(
        sessionID: UUID,
        sessionDirectory: URL,
        windows: [WindowInput]
    ) -> SessionCompactionPlan {
        let windowPlans: [WindowCompactionPlan] = windows.compactMap { window in
            let ordered = window.frames.sorted { lhs, rhs in
                lhs.capturedAt == rhs.capturedAt ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.capturedAt < rhs.capturedAt
            }
            guard ordered.count >= minimumFramesPerWindow else { return nil }

            let maxWidth = ordered.map(\.pixelWidth).max() ?? 0
            let maxHeight = ordered.map(\.pixelHeight).max() ?? 0
            let canvasWidth = maxWidth > 0 ? maxWidth - (maxWidth % 2) : 0
            let canvasHeight = maxHeight > 0 ? maxHeight - (maxHeight % 2) : 0

            return WindowCompactionPlan(
                windowID: window.windowID,
                displayNumber: window.displayNumber,
                outputURL: sessionDirectory.appending(path: "window-\(window.displayNumber).mov"),
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                frames: ordered
            )
        }

        return SessionCompactionPlan(sessionID: sessionID, windows: windowPlans)
    }
}
