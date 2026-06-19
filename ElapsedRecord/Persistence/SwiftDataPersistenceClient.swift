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

        session.endedAt = endedAt
        try context.save()
    }

    func closeOpenSessions(endedAt: Date) throws -> Int {
        let context = ModelContext(modelContainer)
        let sessions = try context.fetch(FetchDescriptor<CaptureSessionModel>())
            .filter { $0.endedAt == nil }

        for session in sessions {
            session.endedAt = endedAt
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

    private func allSessions() throws -> [CaptureSessionModel] {
        let context = ModelContext(modelContainer)
        return try context.fetch(FetchDescriptor<CaptureSessionModel>())
    }

    private func sessionModel(id: UUID, context: ModelContext) throws -> CaptureSessionModel? {
        try context.fetch(FetchDescriptor<CaptureSessionModel>())
            .first { $0.id == id }
    }

    private func windowModel(id: UUID, context: ModelContext) throws -> MonitoredWindowModel? {
        try context.fetch(FetchDescriptor<MonitoredWindowModel>())
            .first { $0.id == id }
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
            upsertWindow: { window in
                try await store.upsertWindow(window)
            },
            recordScreenshot: { record in
                try await store.recordScreenshot(record)
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
            }
        )
    }

    static let unavailable = Self(
        openSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        closeSession: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        closeOpenSessions: { _ in throw CaptureEngineError.persistenceUnavailable },
        deleteSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        upsertWindow: { _ in throw CaptureEngineError.persistenceUnavailable },
        recordScreenshot: { _ in throw CaptureEngineError.persistenceUnavailable },
        apps: { throw CaptureEngineError.persistenceUnavailable },
        sessions: { _ in throw CaptureEngineError.persistenceUnavailable },
        windows: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForWindow: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForApp: { _ in throw CaptureEngineError.persistenceUnavailable }
    )
}
