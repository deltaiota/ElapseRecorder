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
            syncTitleObservations(window.titleHistory, into: model, context: context)
        } else {
            let model = MonitoredWindowModel(
                id: window.id,
                systemWindowID: window.systemWindowID,
                displayNumber: window.displayNumber,
                label: window.label,
                firstSeenAt: window.firstSeenAt,
                lastSeenAt: window.lastSeenAt,
                session: session
            )
            context.insert(model)
            syncTitleObservations(window.titleHistory, into: model, context: context)
        }

        try context.save()
    }

    /// Insert any title observations not already persisted for this window. The engine
    /// re-sends the window's full title history each tick, so matching on the observation's
    /// stable id keeps each rename recorded exactly once.
    private func syncTitleObservations(
        _ history: [WindowTitleObservation],
        into model: MonitoredWindowModel,
        context: ModelContext
    ) {
        let existingIDs = Set(model.titleObservations.map(\.id))
        for observation in history where !existingIDs.contains(observation.id) {
            context.insert(
                WindowTitleObservationModel(
                    id: observation.id,
                    title: observation.title,
                    observedAt: observation.observedAt,
                    window: model
                )
            )
        }
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

        // Upsert so an ongoing unavailable span (same id, growing endedAt) extends the
        // existing record instead of inserting a new placeholder each tick.
        if let existing = try unavailableRecordModel(id: record.id, context: context) {
            existing.endedAt = record.endedAt
            try context.save()
            return
        }

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

    func sessionTimeline(_ sessionID: UUID) throws -> SessionTimeline {
        let context = ModelContext(modelContainer)
        guard let session = try sessionModel(id: sessionID, context: context) else {
            throw CaptureEngineError.sessionNotFound(sessionID)
        }

        let lanes = session.windows
            .sorted { $0.displayNumber < $1.displayNumber }
            .map(windowLane)

        let unavailableSpans = session.unavailableRecords
            .sorted { $0.startedAt < $1.startedAt }
            .map { TimeSpan(startedAt: $0.startedAt, endedAt: $0.endedAt) }

        return SessionTimeline(
            sessionID: sessionID,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            lanes: lanes,
            unavailableSpans: unavailableSpans
        )
    }

    private func windowLane(_ window: MonitoredWindowModel) -> WindowLane {
        let bornAt = window.firstSeenAt
        let diedAt = max(window.firstSeenAt, window.lastSeenAt)
        let screenshotTimes = window.screenshots.map(\.capturedAt).sorted()
        let observations = window.titleObservations.sorted { $0.observedAt < $1.observedAt }

        return WindowLane(
            windowID: window.id,
            displayNumber: window.displayNumber,
            systemWindowID: window.systemWindowID,
            bornAt: bornAt,
            diedAt: diedAt,
            segments: titleSegments(
                observations: observations,
                fallbackID: window.id,
                fallbackTitle: window.label,
                bornAt: bornAt,
                diedAt: diedAt,
                screenshotTimes: screenshotTimes
            ),
            screenshotCount: screenshotTimes.count
        )
    }

    /// Split a window's life into constant-title segments. Each title observation starts a
    /// new segment that runs until the next observation (or the window's death). A window
    /// with no recorded observations still yields one whole-life segment.
    private func titleSegments(
        observations: [WindowTitleObservationModel],
        fallbackID: UUID,
        fallbackTitle: String?,
        bornAt: Date,
        diedAt: Date,
        screenshotTimes: [Date]
    ) -> [WindowTitleSegment] {
        guard !observations.isEmpty else {
            return [
                WindowTitleSegment(
                    id: fallbackID,
                    title: fallbackTitle,
                    startedAt: bornAt,
                    endedAt: diedAt,
                    screenshotCount: screenshotTimes.count
                ),
            ]
        }

        return observations.enumerated().map { index, observation in
            let isLast = index + 1 == observations.count
            let startedAt = index == 0 ? bornAt : observation.observedAt
            let endedAt = isLast ? diedAt : observations[index + 1].observedAt

            // Count screenshots inside the segment; the final segment includes its end so a
            // capture taken at the window's last-seen instant isn't dropped.
            let screenshotCount = screenshotTimes.filter { time in
                time >= startedAt && (isLast ? time <= endedAt : time < endedAt)
            }.count

            return WindowTitleSegment(
                id: observation.id,
                title: observation.title,
                startedAt: startedAt,
                endedAt: max(startedAt, endedAt),
                screenshotCount: screenshotCount
            )
        }
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

    private func unavailableRecordModel(id: UUID, context: ModelContext) throws -> CaptureUnavailableRecordModel? {
        try context.fetch(FetchDescriptor<CaptureUnavailableRecordModel>())
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
                container = try ModelContainer.elapseRecorder()
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
            },
            sessionTimeline: { sessionID in
                try await store.sessionTimeline(sessionID)
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
        timelineForApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        sessionTimeline: { _ in throw CaptureEngineError.persistenceUnavailable }
    )
}
