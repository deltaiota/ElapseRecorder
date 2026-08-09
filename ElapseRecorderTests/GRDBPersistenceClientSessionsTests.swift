@testable import ElapseRecorder
import Foundation
import XCTest

final class GRDBPersistenceClientSessionsTests: GRDBPersistenceTestCase {
    @MainActor
    func testCloseOpenSessionsAndDeleteSession() async throws {
        let client = try temporaryClient()
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
        let client = try temporaryClient()
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
        let client = try temporaryClient()
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
        let client = try temporaryClient()

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

        let timeline = try await client.sessionTimeline(session.id)
        let segments = try XCTUnwrap(timeline.lanes.first).segments
        XCTAssertEqual(segments.map(\.title), ["Untitled", "Notes.txt"])
        XCTAssertEqual(segments.map(\.id), [firstObservation.id, secondObservation.id])
    }
}
