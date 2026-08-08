import Foundation

/// An immutable description of a chronological frame scope. The descriptor can be retained by
/// presentation, export, and cadence features without retaining every matching frame record.
nonisolated struct FrameQuery: Equatable, Hashable {
    nonisolated enum Scope: Equatable, Hashable {
        case app(bundleIdentifier: String)
        case session(id: UUID)
        case window(sessionID: UUID, windowID: UUID)
    }

    let scope: Scope
    /// Inclusive capture-time bounds. `nil` means the complete scope.
    let capturedAt: ClosedRange<Date>?
    /// Inclusive terminal keyset coordinate used to freeze multi-pass readers such as export.
    let through: FrameCursor?

    init(scope: Scope, capturedAt: ClosedRange<Date>? = nil, through: FrameCursor? = nil) {
        self.scope = scope
        self.capturedAt = capturedAt
        self.through = through
    }
}

extension FrameQuery {
    func matches(_ record: ScreenshotRecord, bundleIdentifier: String) -> Bool {
        let scopeMatches = switch scope {
        case let .app(expectedBundleIdentifier):
            expectedBundleIdentifier == bundleIdentifier
        case let .session(id):
            id == record.sessionID
        case let .window(sessionID, windowID):
            sessionID == record.sessionID && windowID == record.windowID
        }
        guard scopeMatches else { return false }
        if let capturedAt, !capturedAt.contains(record.capturedAt) { return false }
        guard let through else { return true }
        if record.capturedAt != through.capturedAt {
            return record.capturedAt < through.capturedAt
        }
        return record.id.uuidString <= through.id.uuidString
    }
}

/// Exclusive keyset cursor for a `FrameQuery`. Frames are ordered chronologically by
/// `(capturedAt, id)`, so equal timestamps remain stable and no page can skip or repeat a frame.
nonisolated struct FrameCursor: Equatable, Hashable {
    let capturedAt: Date
    let id: UUID

    init(capturedAt: Date, id: UUID) {
        self.capturedAt = capturedAt
        self.id = id
    }

    init(frame: ScreenshotRecord) {
        self.init(capturedAt: frame.capturedAt, id: frame.id)
    }
}

/// One bounded presentation/export page. `totalCount` describes the whole immutable query scope,
/// not just this page. A nil cursor means the page reached the end of the scope.
nonisolated struct FramePage: Equatable {
    let frames: [ScreenshotRecord]
    let nextCursor: FrameCursor?
    let totalCount: Int

    init(frames: [ScreenshotRecord], nextCursor: FrameCursor?, totalCount: Int) {
        self.frames = frames
        self.nextCursor = nextCursor
        self.totalCount = max(0, totalCount)
    }

    static let empty = Self(frames: [], nextCursor: nil, totalCount: 0)
}

nonisolated struct FrameQuerySnapshot: Equatable {
    let selection: FrameSelection
    let count: Int

    init(selection: FrameSelection, count: Int) {
        self.selection = selection
        self.count = max(0, count)
    }
}

/// Export/cadence scope. A query represents every matching frame, while explicit ids preserve the
/// user's selection order without widening it to the currently visible presentation page.
nonisolated enum FrameSelection: Equatable, Hashable {
    case query(FrameQuery)
    case ids([UUID])
}
