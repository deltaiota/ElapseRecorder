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

    @MainActor
    func testSessionTimelineAssemblesLanesSegmentsAndUnavailableSpans() async throws {
        let container = try inMemoryContainer()
        let client = PersistenceClient.live(modelContainer: container)

        let session = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000601"),
            bundleIdentifier: "com.example.TextApp",
            displayName: "Text App",
            processIdentifier: 601,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try await client.openSession(session)

        let firstObservation = try WindowTitleObservation(
            id: uuid("00000000-0000-0000-0000-000000000701"),
            title: "Untitled",
            observedAt: Date(timeIntervalSince1970: 110)
        )
        let secondObservation = try WindowTitleObservation(
            id: uuid("00000000-0000-0000-0000-000000000702"),
            title: "Notes.txt",
            observedAt: Date(timeIntervalSince1970: 150)
        )
        let window = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000603"),
            sessionID: session.id,
            systemWindowID: 700,
            displayNumber: 1,
            label: "Untitled",
            firstSeenAt: Date(timeIntervalSince1970: 110),
            lastSeenAt: Date(timeIntervalSince1970: 200),
            titleHistory: [firstObservation, secondObservation]
        )
        try await client.upsertWindow(window)

        // Two screenshots in the "Untitled" segment [110, 150), two in "Notes.txt" [150, 200].
        for (index, capturedAt) in [110, 130, 160, 200].enumerated() {
            let screenshot = try ScreenshotRecord(
                id: uuid("00000000-0000-0000-0000-00000000080\(index)"),
                windowID: window.id,
                sessionID: session.id,
                capturedAt: Date(timeIntervalSince1970: TimeInterval(capturedAt)),
                fileURL: URL(filePath: "/tmp/shot-\(index).heic"),
                fileSizeBytes: 10
            )
            try await client.recordScreenshot(screenshot)
        }

        let unavailable = try CaptureUnavailableRecord(
            id: uuid("00000000-0000-0000-0000-000000000901"),
            sessionID: session.id,
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 210),
            reason: .windowMinimized
        )
        try await client.recordCaptureUnavailable(unavailable)

        let timeline = try await client.sessionTimeline(session.id)

        XCTAssertEqual(timeline.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(timeline.endedAt)
        XCTAssertEqual(timeline.unavailableSpans, [
            TimeSpan(startedAt: Date(timeIntervalSince1970: 200), endedAt: Date(timeIntervalSince1970: 210)),
        ])

        let lane = try XCTUnwrap(timeline.lanes.first)
        XCTAssertEqual(timeline.lanes.count, 1)
        XCTAssertEqual(lane.windowID, window.id)
        XCTAssertEqual(lane.displayNumber, 1)
        XCTAssertEqual(lane.bornAt, Date(timeIntervalSince1970: 110))
        XCTAssertEqual(lane.diedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(lane.screenshotCount, 4)

        XCTAssertEqual(lane.segments.map(\.title), ["Untitled", "Notes.txt"])
        XCTAssertEqual(lane.segments.map(\.id), [firstObservation.id, secondObservation.id])
        XCTAssertEqual(
            lane.segments.map(\.startedAt),
            [Date(timeIntervalSince1970: 110), Date(timeIntervalSince1970: 150)]
        )
        XCTAssertEqual(
            lane.segments.map(\.endedAt),
            [Date(timeIntervalSince1970: 150), Date(timeIntervalSince1970: 200)]
        )
        // First segment [110,150): captures at 110 and 130. Second [150,200]: 160 and 200.
        XCTAssertEqual(lane.segments.map(\.screenshotCount), [2, 2])
    }

    @MainActor
    func testScreenshotDimensionsAndPerceptualHashRoundTrip() async throws {
        let client = try PersistenceClient.live(modelContainer: inMemoryContainer())

        let session = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000801"),
            bundleIdentifier: "com.example.HashApp",
            displayName: "Hash App",
            processIdentifier: 301,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try await client.openSession(session)

        let window = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000802"),
            sessionID: session.id,
            systemWindowID: 900,
            displayNumber: 1,
            label: "Canvas",
            firstSeenAt: Date(timeIntervalSince1970: 110),
            lastSeenAt: Date(timeIntervalSince1970: 110)
        )
        try await client.upsertWindow(window)

        // A hash with the high bit set exercises the UInt64<->Int bit-pattern conversion.
        let hash: UInt64 = 0x8000_0000_0000_00FF
        let screenshot = try ScreenshotRecord(
            id: uuid("00000000-0000-0000-0000-000000000803"),
            windowID: window.id,
            sessionID: session.id,
            capturedAt: Date(timeIntervalSince1970: 120),
            fileURL: URL(filePath: "/tmp/hash.heic"),
            fileSizeBytes: 42,
            pixelWidth: 1920,
            pixelHeight: 1080,
            perceptualHash: hash
        )
        try await client.recordScreenshot(screenshot)

        let stored = try await client.screenshotsForWindow(window.id).first
        XCTAssertEqual(stored?.pixelWidth, 1920)
        XCTAssertEqual(stored?.pixelHeight, 1080)
        XCTAssertEqual(stored?.perceptualHash, hash)
    }

    @MainActor
    func testStorageAggregatesAndMaintenanceQueries() async throws {
        let client = try PersistenceClient.live(modelContainer: inMemoryContainer())

        let oldSession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000901"),
            bundleIdentifier: "com.example.SizeApp",
            displayName: "Size App",
            processIdentifier: 401,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let newSession = try CaptureSession(
            id: uuid("00000000-0000-0000-0000-000000000902"),
            bundleIdentifier: "com.example.SizeApp",
            displayName: "Size App",
            processIdentifier: 402,
            startedAt: Date(timeIntervalSince1970: 5000)
        )
        try await client.openSession(oldSession)
        try await client.openSession(newSession)

        let oldWindow = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000903"),
            sessionID: oldSession.id,
            systemWindowID: 1,
            displayNumber: 1,
            label: "W",
            firstSeenAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 100)
        )
        let newWindow = try MonitoredWindow(
            id: uuid("00000000-0000-0000-0000-000000000904"),
            sessionID: newSession.id,
            systemWindowID: 2,
            displayNumber: 1,
            label: "W",
            firstSeenAt: Date(timeIntervalSince1970: 5000),
            lastSeenAt: Date(timeIntervalSince1970: 5000)
        )
        try await client.upsertWindow(oldWindow)
        try await client.upsertWindow(newWindow)

        let oldShot = try ScreenshotRecord(
            id: uuid("00000000-0000-0000-0000-000000000905"),
            windowID: oldWindow.id,
            sessionID: oldSession.id,
            capturedAt: Date(timeIntervalSince1970: 110),
            fileURL: URL(filePath: "/tmp/old.heic"),
            fileSizeBytes: 100
        )
        let newShot = try ScreenshotRecord(
            id: uuid("00000000-0000-0000-0000-000000000906"),
            windowID: newWindow.id,
            sessionID: newSession.id,
            capturedAt: Date(timeIntervalSince1970: 5010),
            fileURL: URL(filePath: "/tmp/new.heic"),
            fileSizeBytes: 250
        )
        try await client.recordScreenshot(oldShot)
        try await client.recordScreenshot(newShot)

        // Aggregates.
        let app = try await client.apps().first
        XCTAssertEqual(app?.sizeBytes, 350)
        XCTAssertEqual(app?.screenshotCount, 2)
        let sessions = try await client.sessions("com.example.SizeApp")
        XCTAssertEqual(sessions.first(where: { $0.id == oldSession.id })?.sizeBytes, 100)

        // File index + paths.
        let index = try await client.screenshotFileIndex()
        XCTAssertEqual(Set(index.map(\.path)), ["/tmp/old.heic", "/tmp/new.heic"])
        let oldPaths = try await client.screenshotPathsForSession(oldSession.id)
        XCTAssertEqual(oldPaths, ["/tmp/old.heic"])

        // sessionsStartedBefore.
        let older = try await client.sessionsStartedBefore(Date(timeIntervalSince1970: 1000), nil)
        XCTAssertEqual(older.map(\.id), [oldSession.id])

        // deleteScreenshots.
        try await client.deleteScreenshots([oldShot.id])
        let remaining = try await client.screenshotFileIndex()
        XCTAssertEqual(remaining.map(\.path), ["/tmp/new.heic"])
    }

    private func inMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Schema.elapseRecorder, configurations: [configuration])
    }

    private func uuid(_ string: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: string))
    }
}
