import Foundation
import SwiftData

@Model
final class CaptureSessionModel {
    @Attribute(.unique) var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var processIdentifier: Int32
    var startedAt: Date
    var endedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \MonitoredWindowModel.session)
    var windows: [MonitoredWindowModel]

    @Relationship(deleteRule: .cascade, inverse: \ScreenshotRecordModel.session)
    var screenshots: [ScreenshotRecordModel]

    init(
        id: UUID,
        bundleIdentifier: String,
        displayName: String,
        processIdentifier: pid_t,
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.processIdentifier = Int32(processIdentifier)
        self.startedAt = startedAt
        self.endedAt = endedAt
        windows = []
        screenshots = []
    }
}

@Model
final class MonitoredWindowModel {
    @Attribute(.unique) var id: UUID
    var systemWindowID: Int
    var displayNumber: Int
    var label: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var session: CaptureSessionModel?

    @Relationship(deleteRule: .cascade, inverse: \ScreenshotRecordModel.window)
    var screenshots: [ScreenshotRecordModel]

    init(
        id: UUID,
        systemWindowID: Int,
        displayNumber: Int,
        label: String?,
        firstSeenAt: Date,
        lastSeenAt: Date,
        session: CaptureSessionModel?
    ) {
        self.id = id
        self.systemWindowID = systemWindowID
        self.displayNumber = displayNumber
        self.label = label
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.session = session
        screenshots = []
    }
}

@Model
final class ScreenshotRecordModel {
    @Attribute(.unique) var id: UUID
    var capturedAt: Date
    var filePath: String
    var fileSizeBytes: Int
    var session: CaptureSessionModel?
    var window: MonitoredWindowModel?

    init(
        id: UUID,
        capturedAt: Date,
        filePath: String,
        fileSizeBytes: Int,
        session: CaptureSessionModel?,
        window: MonitoredWindowModel?
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.filePath = filePath
        self.fileSizeBytes = fileSizeBytes
        self.session = session
        self.window = window
    }
}

extension Schema {
    static let elapsedRecord = Schema([
        CaptureSessionModel.self,
        MonitoredWindowModel.self,
        ScreenshotRecordModel.self,
    ])
}

extension CaptureSessionModel {
    var isEmpty: Bool {
        windows.isEmpty && screenshots.isEmpty
    }

    var domainValue: CaptureSession {
        CaptureSession(
            id: id,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            processIdentifier: processIdentifier,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    var summaryValue: CaptureSessionSummary {
        CaptureSessionSummary(
            id: id,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            startedAt: startedAt,
            endedAt: endedAt,
            windowCount: windows.count,
            screenshotCount: screenshots.count
        )
    }
}

extension MonitoredWindowModel {
    var domainValue: MonitoredWindow? {
        guard let sessionID = session?.id else { return nil }

        return MonitoredWindow(
            id: id,
            sessionID: sessionID,
            systemWindowID: systemWindowID,
            displayNumber: displayNumber,
            label: label,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt
        )
    }

    var summaryValue: WindowCaptureSummary {
        WindowCaptureSummary(
            id: id,
            displayNumber: displayNumber,
            label: label,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            screenshotCount: screenshots.count
        )
    }
}

extension ScreenshotRecordModel {
    var domainValue: ScreenshotRecord? {
        guard let sessionID = session?.id, let windowID = window?.id else { return nil }

        return ScreenshotRecord(
            id: id,
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: capturedAt,
            fileURL: URL(filePath: filePath),
            fileSizeBytes: fileSizeBytes
        )
    }
}
