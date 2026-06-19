@testable import ElapsedRecord
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

    private func inMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Schema.elapsedRecord, configurations: [configuration])
    }

    private func uuid(_ string: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: string))
    }
}
