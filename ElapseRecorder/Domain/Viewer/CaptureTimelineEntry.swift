import Foundation

nonisolated enum CaptureTimelineEntry: Equatable, Identifiable {
    case screenshot(ScreenshotRecord)
    case unavailable(CaptureUnavailableRecord)

    var id: UUID {
        switch self {
        case let .screenshot(record):
            record.id
        case let .unavailable(record):
            record.id
        }
    }

    var occurredAt: Date {
        switch self {
        case let .screenshot(record):
            record.capturedAt
        case let .unavailable(record):
            record.startedAt
        }
    }
}
