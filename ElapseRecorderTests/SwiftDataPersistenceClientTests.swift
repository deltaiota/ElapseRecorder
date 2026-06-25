@testable import ElapseRecorder
import Foundation
import SwiftData
import XCTest

final class SwiftDataPersistenceClientTests: XCTestCase {
    @MainActor
    func testQueriesReturnExpectedSummariesAndChronologicalScreenshots() async throws {
        let client = try PersistenceClient.live(modelContainer: inMemoryContainer())

        let appSession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000101"),
            bundleIdentifier: "com.example.ArtApp",
            displayName: "Art App",
            processIdentifier: 101,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let laterAppSession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000102"),
            bundleIdentifier: "com.example.ArtApp",
            displayName: "Art App",
            processIdentifier: 102,
            startedAt: Date(timeIntervalSince1970: 300)
        )
        let otherSession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000103"),
            bundleIdentifier: "com.example.CodeApp",
            displayName: "Code App",
            processIdentifier: 201,
            startedAt: Date(timeIntervalSince1970: 50)
        )

        try await client.openSession(appSession)
        try await client.openSession(laterAppSession)
        try await client.openSession(otherSession)
        let firstWindow = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000201"),
            sessionID: appSession.id,
            systemWindowID: 501,
            displayNumber: 2,
            label: "Reference",
            firstSeenAt: Date(timeIntervalSince1970: 110),
            lastSeenAt: Date(timeIntervalSince1970: 130)
        )
        let secondWindow = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000202"),
            sessionID: appSession.id,
            systemWindowID: 777,
            displayNumber: 1,
            label: "Canvas",
            firstSeenAt: Date(timeIntervalSince1970: 120),
            lastSeenAt: Date(timeIntervalSince1970: 140)
        )
        let laterWindow = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000203"),
            sessionID: laterAppSession.id,
            systemWindowID: 888,
            displayNumber: 1,
            label: "Later Canvas",
            firstSeenAt: Date(timeIntervalSince1970: 310),
            lastSeenAt: Date(timeIntervalSince1970: 330)
        )

        try await client.upsertWindow(firstWindow)
        try await client.upsertWindow(secondWindow)
        try await client.upsertWindow(laterWindow)

        let oldScreenshot = try ScreenshotRecord(
            id: uuid("00000000-0000-0000-0000-000000000301"),
            windowID: secondWindow.id,
            sessionID: appSession.id,
            capturedAt: Date(timeIntervalSince1970: 125),
            fileURL: URL(filePath: "/tmp/old.heic"),
            fileSizeBytes: 10
        )
        let newerScreenshot = try ScreenshotRecord(
            id: uuid("00000000-0000-0000-0000-000000000302"),
            windowID: secondWindow.id,
            sessionID: appSession.id,
            capturedAt: Date(timeIntervalSince1970: 135),
            fileURL: URL(filePath: "/tmp/newer.heic"),
            fileSizeBytes: 20
        )
        let laterScreenshot = try ScreenshotRecord(
            id: uuid("00000000-0000-0000-0000-000000000303"),
            windowID: laterWindow.id,
            sessionID: laterAppSession.id,
            capturedAt: Date(timeIntervalSince1970: 320),
            fileURL: URL(filePath: "/tmp/later.heic"),
            fileSizeBytes: 30
        )

        try await client.recordScreenshot(newerScreenshot)
        try await client.recordScreenshot(oldScreenshot)
        try await client.recordScreenshot(laterScreenshot)
        let unavailableRecord = try CaptureUnavailableRecord(
            id: uuid("00000000-0000-0000-0000-000000000304"),
            sessionID: appSession.id,
            startedAt: Date(timeIntervalSince1970: 130),
            endedAt: Date(timeIntervalSince1970: 130),
            reason: .windowMinimized
        )
        try await client.recordCaptureUnavailable(unavailableRecord)
        try await client.closeSession(appSession.id, Date(timeIntervalSince1970: 240))

        let apps = try await client.apps()
        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.example.ArtApp"])
        XCTAssertEqual(apps.first?.sessionCount, 2)
        XCTAssertEqual(apps.first?.screenshotCount, 3)
        XCTAssertEqual(apps.first?.lastCapturedAt, laterScreenshot.capturedAt)
        let codeSessions = try await client.sessions("com.example.CodeApp")
        XCTAssertEqual(codeSessions, [])

        let sessions = try await client.sessions("com.example.ArtApp")
        XCTAssertEqual(sessions.map(\.id), [laterAppSession.id, appSession.id])
        XCTAssertEqual(sessions.last?.endedAt, Date(timeIntervalSince1970: 240))
        XCTAssertEqual(sessions.last?.windowCount, 2)
        XCTAssertEqual(sessions.last?.screenshotCount, 2)

        let windows = try await client.windows(appSession.id)
        XCTAssertEqual(windows.map(\.id), [secondWindow.id, firstWindow.id])
        XCTAssertEqual(windows.first?.screenshotCount, 2)

        let windowScreenshots = try await client.screenshotsForWindow(secondWindow.id)
        XCTAssertEqual(windowScreenshots.map(\.id), [oldScreenshot.id, newerScreenshot.id])

        let sessionScreenshots = try await client.screenshotsForSession(appSession.id)
        XCTAssertEqual(sessionScreenshots.map(\.id), [oldScreenshot.id, newerScreenshot.id])

        let appScreenshots = try await client.screenshotsForApp("com.example.ArtApp")
        XCTAssertEqual(appScreenshots.map(\.id), [oldScreenshot.id, newerScreenshot.id, laterScreenshot.id])

        let sessionTimeline = try await client.timelineForSession(appSession.id)
        XCTAssertEqual(
            sessionTimeline,
            [
                .screenshot(oldScreenshot),
                .unavailable(unavailableRecord),
                .screenshot(newerScreenshot),
            ]
        )

        let windowTimeline = try await client.timelineForWindow(appSession.id, secondWindow.id)
        XCTAssertEqual(
            windowTimeline,
            [
                .screenshot(oldScreenshot),
                .unavailable(unavailableRecord),
                .screenshot(newerScreenshot),
            ]
        )

        let appTimeline = try await client.timelineForApp("com.example.ArtApp")
        XCTAssertEqual(
            appTimeline,
            [
                .screenshot(oldScreenshot),
                .unavailable(unavailableRecord),
                .screenshot(newerScreenshot),
                .screenshot(laterScreenshot),
            ]
        )
    }

    @MainActor
    func testCloseOpenSessionsAndDeleteSession() async throws {
        let client = try PersistenceClient.live(modelContainer: inMemoryContainer())
        let emptySession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000401"),
            bundleIdentifier: "com.example.StaleApp",
            displayName: "Stale App",
            processIdentifier: 401,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let retainedSession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000402"),
            bundleIdentifier: "com.example.StaleApp",
            displayName: "Stale App",
            processIdentifier: 402,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        let window = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000403"),
            sessionID: retainedSession.id,
            systemWindowID: 403,
            displayNumber: 1,
            label: "Main",
            firstSeenAt: Date(timeIntervalSince1970: 210),
            lastSeenAt: Date(timeIntervalSince1970: 220)
        )
        let screenshot = try ScreenshotRecord(
            id: uuid("00000000-0000-0000-0000-000000000404"),
            windowID: window.id,
            sessionID: retainedSession.id,
            capturedAt: Date(timeIntervalSince1970: 215),
            fileURL: URL(filePath: "/tmp/stale.heic"),
            fileSizeBytes: 40
        )

        try await client.openSession(emptySession)
        try await client.openSession(retainedSession)
        try await client.upsertWindow(window)
        try await client.recordScreenshot(screenshot)

        let closedCount = try await client.closeOpenSessions(Date(timeIntervalSince1970: 300))
        XCTAssertEqual(closedCount, 2)
        var sessions = try await client.sessions("com.example.StaleApp")
        XCTAssertEqual(sessions.map(\.id), [retainedSession.id])
        XCTAssertEqual(sessions.first?.endedAt, Date(timeIntervalSince1970: 300))

        try await client.deleteSession(retainedSession.id)
        sessions = try await client.sessions("com.example.StaleApp")
        XCTAssertEqual(sessions, [])
    }

    @MainActor
    func testCloseOpenSessionsSkipsSessionsStartedAfterCutoff() async throws {
        let client = try PersistenceClient.live(modelContainer: inMemoryContainer())
        let priorRunSession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000501"),
            bundleIdentifier: "com.example.CutoffApp",
            displayName: "Cutoff App",
            processIdentifier: 501,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let currentRunSession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000502"),
            bundleIdentifier: "com.example.CutoffApp",
            displayName: "Cutoff App",
            processIdentifier: 502,
            startedAt: Date(timeIntervalSince1970: 400)
        )
        let currentWindow = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000503"),
            sessionID: currentRunSession.id,
            systemWindowID: 503,
            displayNumber: 1,
            label: "Main",
            firstSeenAt: Date(timeIntervalSince1970: 410),
            lastSeenAt: Date(timeIntervalSince1970: 420)
        )
        let currentScreenshot = try ScreenshotRecord(
            id: uuid("00000000-0000-0000-0000-000000000504"),
            windowID: currentWindow.id,
            sessionID: currentRunSession.id,
            capturedAt: Date(timeIntervalSince1970: 415),
            fileURL: URL(filePath: "/tmp/current.heic"),
            fileSizeBytes: 40
        )

        try await client.openSession(priorRunSession)
        try await client.openSession(currentRunSession)
        try await client.upsertWindow(currentWindow)
        try await client.recordScreenshot(currentScreenshot)

        // The cutoff sits between the two runs: only sessions started before it are stale.
        // The prior run's empty session is cleaned up while the current run's session
        // (started after launch) is left open.
        let closedCount = try await client.closeOpenSessions(Date(timeIntervalSince1970: 300))
        XCTAssertEqual(closedCount, 1)

        let sessions = try await client.sessions("com.example.CutoffApp")
        XCTAssertEqual(sessions.map(\.id), [currentRunSession.id])
        XCTAssertTrue(sessions.allSatisfy { $0.endedAt == nil })
    }

    @MainActor
    func testClosingEmptySessionDeletesIt() async throws {
        let client = try PersistenceClient.live(modelContainer: inMemoryContainer())
        let emptySession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000405"),
            bundleIdentifier: "com.example.EmptyApp",
            displayName: "Empty App",
            processIdentifier: 405,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        try await client.openSession(emptySession)
        try await client.closeSession(emptySession.id, Date(timeIntervalSince1970: 120))

        let apps = try await client.apps()
        let sessions = try await client.sessions(emptySession.bundleIdentifier)
        XCTAssertEqual(apps, [])
        XCTAssertEqual(sessions, [])
    }

    @MainActor
    func testWindowTitleHistoryIsPersistedAndDeduplicated() async throws {
        let container = try inMemoryContainer()
        let client = PersistenceClient.live(modelContainer: container)

        let session = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000401"),
            bundleIdentifier: "com.example.TextApp",
            displayName: "Text App",
            processIdentifier: 401,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try await client.openSession(session)

        let firstObservation = try WindowTitleObservation(
            id: uuid("00000000-0000-0000-0000-000000000501"),
            title: "Untitled",
            observedAt: Date(timeIntervalSince1970: 110)
        )
        let secondObservation = try WindowTitleObservation(
            id: uuid("00000000-0000-0000-0000-000000000502"),
            title: "Notes.txt",
            observedAt: Date(timeIntervalSince1970: 130)
        )

        var window = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000403"),
            sessionID: session.id,
            systemWindowID: 700,
            displayNumber: 1,
            label: "Untitled",
            firstSeenAt: Date(timeIntervalSince1970: 110),
            lastSeenAt: Date(timeIntervalSince1970: 110),
            titleHistory: [firstObservation]
        )
        try await client.upsertWindow(window)

        // A later tick adds a rename; the engine re-sends the full history each time.
        window.lastSeenAt = Date(timeIntervalSince1970: 130)
        window.titleHistory = [firstObservation, secondObservation]
        try await client.upsertWindow(window)

        // Re-upserting the identical history must not duplicate observations.
        try await client.upsertWindow(window)

        let context = ModelContext(container)
        let models = try context.fetch(FetchDescriptor<MonitoredWindowModel>())
        let stored = try XCTUnwrap(models.first { $0.id == window.id })
        let history = stored.titleObservations.sorted { $0.observedAt < $1.observedAt }

        XCTAssertEqual(history.map(\.title), ["Untitled", "Notes.txt"])
        XCTAssertEqual(history.map(\.id), [firstObservation.id, secondObservation.id])

        let domainHistory = try XCTUnwrap(stored.domainValue).titleHistory
        XCTAssertEqual(domainHistory.map(\.title), ["Untitled", "Notes.txt"])
    }

    private func inMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Schema.elapseRecorder, configurations: [configuration])
    }

    private func uuid(_ string: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: string))
    }
}
