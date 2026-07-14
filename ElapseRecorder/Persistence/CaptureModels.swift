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

    @Relationship(deleteRule: .cascade, inverse: \CaptureUnavailableRecordModel.session)
    var unavailableRecords: [CaptureUnavailableRecordModel]

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
        unavailableRecords = []
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

    @Relationship(deleteRule: .cascade, inverse: \WindowTitleObservationModel.window)
    var titleObservations: [WindowTitleObservationModel]

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
        titleObservations = []
    }
}

@Model
final class WindowTitleObservationModel {
    @Attribute(.unique) var id: UUID
    var title: String?
    var observedAt: Date
    var window: MonitoredWindowModel?

    init(
        id: UUID,
        title: String?,
        observedAt: Date,
        window: MonitoredWindowModel?
    ) {
        self.id = id
        self.title = title
        self.observedAt = observedAt
        self.window = window
    }
}

@Model
final class ScreenshotRecordModel {
    @Attribute(.unique) var id: UUID
    var capturedAt: Date
    var filePath: String
    var fileSizeBytes: Int
    // Defaulted so SwiftData can lightweight-migrate existing stores. Zero = unknown/not
    // computed for records written before these fields existed.
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// Stored as the bit pattern of the 64-bit dHash (SwiftData has no UInt64 type).
    var perceptualHash: Int = 0
    var session: CaptureSessionModel?
    var window: MonitoredWindowModel?

    init(
        id: UUID,
        capturedAt: Date,
        filePath: String,
        fileSizeBytes: Int,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        perceptualHash: UInt64 = 0,
        session: CaptureSessionModel?,
        window: MonitoredWindowModel?
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.filePath = filePath
        self.fileSizeBytes = fileSizeBytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.perceptualHash = Int(bitPattern: UInt(perceptualHash))
        self.session = session
        self.window = window
    }
}

@Model
final class CaptureUnavailableRecordModel {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date
    var reason: String
    var session: CaptureSessionModel?

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        reason: CaptureUnavailableReason,
        session: CaptureSessionModel?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason.rawValue
        self.session = session
    }
}

extension Schema {
    static let elapseRecorder = Schema([
        CaptureSessionModel.self,
        MonitoredWindowModel.self,
        WindowTitleObservationModel.self,
        ScreenshotRecordModel.self,
        CaptureUnavailableRecordModel.self,
    ])
}

extension ModelContainer {
    /// Builds the app's SwiftData container backed by a stable, app-owned store URL so it
    /// opens reliably in signed, non-sandboxed builds.
    static func elapseRecorder() throws -> ModelContainer {
        let configuration = try ModelConfiguration(
            schema: .elapseRecorder,
            url: FileStoragePaths.databaseURL()
        )
        return try ModelContainer(for: .elapseRecorder, configurations: configuration)
    }
}

extension CaptureSessionModel {
    var isEmpty: Bool {
        windows.isEmpty && screenshots.isEmpty && unavailableRecords.isEmpty
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
            screenshotCount: screenshots.count,
            sizeBytes: screenshots.reduce(0) { $0 + $1.fileSizeBytes }
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
            lastSeenAt: lastSeenAt,
            titleHistory: titleObservations
                .sorted { $0.observedAt < $1.observedAt }
                .map(\.domainValue)
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

extension WindowTitleObservationModel {
    var domainValue: WindowTitleObservation {
        WindowTitleObservation(id: id, title: title, observedAt: observedAt)
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
            fileSizeBytes: fileSizeBytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            perceptualHash: UInt64(bitPattern: Int64(perceptualHash))
        )
    }
}

extension CaptureUnavailableRecordModel {
    var domainValue: CaptureUnavailableRecord? {
        guard let sessionID = session?.id,
              let reason = CaptureUnavailableReason(rawValue: reason)
        else {
            return nil
        }

        return CaptureUnavailableRecord(
            id: id,
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            reason: reason
        )
    }
}
