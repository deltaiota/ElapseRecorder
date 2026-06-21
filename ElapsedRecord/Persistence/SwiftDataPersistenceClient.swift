import Foundation
import SwiftData

@MainActor
final class SwiftDataPersistenceStore {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func openSession(_ session: CaptureSession) throws {
        let context = ModelContext(modelContainer)
        context.insert(
            CaptureSessionModel(
                id: session.id,
                bundleIdentifier: session.bundleIdentifier,
                displayName: session.displayName,
                processIdentifier: session.processIdentifier,
                startedAt: session.startedAt,
                endedAt: session.endedAt
            )
        )
        try context.save()
    }

    func closeSession(_ sessionID: UUID, endedAt: Date) throws {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(sessionID)
        }

        if session.isEmpty {
            context.delete(session)
        } else {
            session.endedAt = endedAt
        }
        try context.save()
    }

    func closeOpenSessions(endedAt: Date) throws -> Int {
        let context = ModelContext(modelContainer)
        // Only close sessions that were opened before this cutoff (the app's launch
        // time). Sessions started at or after the cutoff belong to the current run and
        // must never be closed by stale cleanup, even if the cleanup races with the
        // capture engine opening a fresh session at startup.
        let sessions = try context.fetch(FetchDescriptor<CaptureSessionModel>())
            .filter { $0.endedAt == nil && $0.startedAt < endedAt }

        for session in sessions {
            if session.isEmpty {
                context.delete(session)
            } else {
                session.endedAt = endedAt
            }
        }

        guard !sessions.isEmpty else { return 0 }
        try context.save()
        return sessions.count
    }

    func deleteSession(_ sessionID: UUID) throws {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(sessionID)
        }

        context.delete(session)
        try context.save()
    }

    func deleteApp(_ bundleIdentifier: String) throws {
        let context = ModelContext(modelContainer)
        let sessions = try context.fetch(FetchDescriptor<CaptureSessionModel>())
            .filter { $0.bundleIdentifier == bundleIdentifier }

        for session in sessions {
            context.delete(session)
        }

        guard !sessions.isEmpty else { return }
        try context.save()
    }

    func upsertWindow(_ window: MonitoredWindow) throws {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: window.sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(window.sessionID)
        }

        if let model = try windowModel(id: window.id, context: context) {
            model.label = window.label
            model.lastSeenAt = window.lastSeenAt
        } else {
            context.insert(
                MonitoredWindowModel(
                    id: window.id,
                    systemWindowID: window.systemWindowID,
                    displayNumber: window.displayNumber,
                    label: window.label,
                    firstSeenAt: window.firstSeenAt,
                    lastSeenAt: window.lastSeenAt,
                    session: session
                )
            )
        }

        try context.save()
    }

    func recordScreenshot(_ record: ScreenshotRecord) throws {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: record.sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(record.sessionID)
        }
        guard let window = try windowModel(id: record.windowID, context: context) else {
            throw CaptureEngineError.sessionNotFound(record.sessionID)
        }

        context.insert(
            ScreenshotRecordModel(
                id: record.id,
                capturedAt: record.capturedAt,
                filePath: record.fileURL.path(percentEncoded: false),
                fileSizeBytes: record.fileSizeBytes,
                session: session,
                window: window
            )
        )
        try context.save()
    }

    func recordCaptureUnavailable(_ record: CaptureUnavailableRecord) throws {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: record.sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(record.sessionID)
        }

        context.insert(
            CaptureUnavailableRecordModel(
                id: record.id,
                startedAt: record.startedAt,
                endedAt: record.endedAt,
                reason: record.reason,
                session: session
            )
        )
        try context.save()
    }

    func apps() throws -> [AppCaptureSummary] {
        let sessions = try allSessions()
        let grouped = Dictionary(grouping: sessions, by: \.bundleIdentifier)

        return grouped.values
            .map { sessions in
                let screenshots = sessions.flatMap(\.screenshots)
                let latest = screenshots.map(\.capturedAt).max()
                let latestSession = sessions.max { $0.startedAt < $1.startedAt }

                return AppCaptureSummary(
                    bundleIdentifier: latestSession?.bundleIdentifier ?? "",
                    displayName: latestSession?.displayName ?? "",
                    sessionCount: sessions.count,
                    screenshotCount: screenshots.count,
                    lastCapturedAt: latest
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.lastCapturedAt, rhs.lastCapturedAt) {
                case let (lhs?, rhs?):
                    lhs > rhs
                case (_?, nil):
                    true
                case (nil, _?):
                    false
                case (nil, nil):
                    lhs.displayName < rhs.displayName
                }
            }
    }

    func sessions(bundleIdentifier: String) throws -> [CaptureSessionSummary] {
        try allSessions()
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .sorted { $0.startedAt > $1.startedAt }
            .map(\.summaryValue)
    }

    func windows(sessionID: UUID) throws -> [WindowCaptureSummary] {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(sessionID)
        }

        return session.windows
            .sorted { $0.displayNumber < $1.displayNumber }
            .map(\.summaryValue)
    }

    func screenshotsForSession(_ sessionID: UUID) throws -> [ScreenshotRecord] {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(sessionID)
        }

        return session.screenshots
            .sorted { $0.capturedAt < $1.capturedAt }
            .compactMap(\.domainValue)
    }

    func screenshotsForWindow(_ windowID: UUID) throws -> [ScreenshotRecord] {
        let context = ModelContext(modelContainer)
        guard let window = try windowModel(id: windowID, context: context) else { return [] }

        return window.screenshots
            .sorted { $0.capturedAt < $1.capturedAt }
            .compactMap(\.domainValue)
    }

    func screenshotsForApp(_ bundleIdentifier: String) throws -> [ScreenshotRecord] {
        try allSessions()
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .flatMap(\.screenshots)
            .sorted { $0.capturedAt < $1.capturedAt }
            .compactMap(\.domainValue)
    }

    func timelineForSession(_ sessionID: UUID) throws -> [CaptureTimelineEntry] {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(sessionID)
        }

        return timelineEntries(
            screenshots: session.screenshots.compactMap(\.domainValue),
            unavailableRecords: session.unavailableRecords.compactMap(\.domainValue)
        )
    }

    func timelineForWindow(sessionID: UUID, windowID: UUID) throws -> [CaptureTimelineEntry] {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(sessionID)
        }
        guard let window = try windowModel(id: windowID, context: context) else {
            return []
        }

        return timelineEntries(
            screenshots: window.screenshots.compactMap(\.domainValue),
            unavailableRecords: session.unavailableRecords.compactMap(\.domainValue)
        )
    }

    func timelineForApp(_ bundleIdentifier: String) throws -> [CaptureTimelineEntry] {
        let sessions = try allSessions()
            .filter { $0.bundleIdentifier == bundleIdentifier }

        return timelineEntries(
            screenshots: sessions.flatMap(\.screenshots).compactMap(\.domainValue),
            unavailableRecords: sessions.flatMap(\.unavailableRecords).compactMap(\.domainValue)
        )
    }

    private func allSessions() throws -> [CaptureSessionModel] {
        let context = ModelContext(modelContainer)
        return try context.fetch(FetchDescriptor<CaptureSessionModel>())
            .filter { !$0.isEmpty }
    }

    private func sessionModel(id: UUID, context: ModelContext) throws -> CaptureSessionModel? {
        try context.fetch(FetchDescriptor<CaptureSessionModel>())
            .first { $0.id == id }
    }

    private func windowModel(id: UUID, context: ModelContext) throws -> MonitoredWindowModel? {
        try context.fetch(FetchDescriptor<MonitoredWindowModel>())
            .first { $0.id == id }
    }

    private func timelineEntries(
        screenshots: [ScreenshotRecord],
        unavailableRecords: [CaptureUnavailableRecord]
    ) -> [CaptureTimelineEntry] {
        (
            screenshots.map(CaptureTimelineEntry.screenshot)
                + unavailableRecords.map(CaptureTimelineEntry.unavailable)
        )
        .sorted { $0.occurredAt < $1.occurredAt }
    }
}

extension PersistenceClient {
    static func live(modelContainer: ModelContainer? = nil) -> Self {
        let container: ModelContainer
        do {
            if let modelContainer {
                container = modelContainer
            } else {
                container = try ModelContainer(for: Schema.elapsedRecord)
            }
        } catch {
            return unavailable
        }

        let store = SwiftDataPersistenceStore(modelContainer: container)

        return Self(
            openSession: { session in
                try await store.openSession(session)
            },
            closeSession: { sessionID, endedAt in
                try await store.closeSession(sessionID, endedAt: endedAt)
            },
            closeOpenSessions: { endedAt in
                try await store.closeOpenSessions(endedAt: endedAt)
            },
            deleteSession: { sessionID in
                try await store.deleteSession(sessionID)
            },
            deleteApp: { bundleIdentifier in
                try await store.deleteApp(bundleIdentifier)
            },
            upsertWindow: { window in
                try await store.upsertWindow(window)
            },
            recordScreenshot: { record in
                try await store.recordScreenshot(record)
            },
            recordCaptureUnavailable: { record in
                try await store.recordCaptureUnavailable(record)
            },
            apps: {
                try await store.apps()
            },
            sessions: { bundleIdentifier in
                try await store.sessions(bundleIdentifier: bundleIdentifier)
            },
            windows: { sessionID in
                try await store.windows(sessionID: sessionID)
            },
            screenshotsForSession: { sessionID in
                try await store.screenshotsForSession(sessionID)
            },
            screenshotsForWindow: { windowID in
                try await store.screenshotsForWindow(windowID)
            },
            screenshotsForApp: { bundleIdentifier in
                try await store.screenshotsForApp(bundleIdentifier)
            },
            timelineForSession: { sessionID in
                try await store.timelineForSession(sessionID)
            },
            timelineForWindow: { sessionID, windowID in
                try await store.timelineForWindow(sessionID: sessionID, windowID: windowID)
            },
            timelineForApp: { bundleIdentifier in
                try await store.timelineForApp(bundleIdentifier)
            }
        )
    }

    static let unavailable = Self(
        openSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        closeSession: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        closeOpenSessions: { _ in throw CaptureEngineError.persistenceUnavailable },
        deleteSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        deleteApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        upsertWindow: { _ in throw CaptureEngineError.persistenceUnavailable },
        recordScreenshot: { _ in throw CaptureEngineError.persistenceUnavailable },
        recordCaptureUnavailable: { _ in throw CaptureEngineError.persistenceUnavailable },
        apps: { throw CaptureEngineError.persistenceUnavailable },
        sessions: { _ in throw CaptureEngineError.persistenceUnavailable },
        windows: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForWindow: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        timelineForSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        timelineForWindow: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        timelineForApp: { _ in throw CaptureEngineError.persistenceUnavailable }
    )
}
