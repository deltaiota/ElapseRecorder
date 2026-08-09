@testable import ElapseRecorder
import Foundation
import XCTest

final class GRDBPersistenceTimelineTests: GRDBPersistenceTestCase {
    @MainActor
    func testSessionTimelineAssemblesLanesSegmentsAndUnavailableSpans() async throws {
        let client = try temporaryClient()

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
        let client = try temporaryClient()

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
        let client = try temporaryClient()

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

    @MainActor
    func testAppSummaryTotalActiveDurationSumsSessionSpans() async throws {
        let client = try temporaryClient()
        let bundleID = "com.example.ArtApp"

        // Ended session: explicit 140s span (100...240).
        let endedID = try uuid("00000000-0000-0000-0000-0000000000E1")
        try await client.openSession(CaptureSession(
            id: endedID, bundleIdentifier: bundleID, displayName: "Art App",
            processIdentifier: 1, startedAt: Date(timeIntervalSince1970: 100)
        ))
        let endedWindow = try uuid("00000000-0000-0000-0000-0000000000E2")
        try await client.upsertWindow(MonitoredWindow(
            id: endedWindow, sessionID: endedID, systemWindowID: 1, displayNumber: 1,
            label: nil, firstSeenAt: Date(timeIntervalSince1970: 100), lastSeenAt: Date(timeIntervalSince1970: 240)
        ))
        try await client.recordScreenshot(ScreenshotRecord(
            id: UUID(), windowID: endedWindow, sessionID: endedID,
            capturedAt: Date(timeIntervalSince1970: 150),
            fileURL: URL(filePath: "/tmp/e1.heic"), fileSizeBytes: 10
        ))
        try await client.closeSession(endedID, Date(timeIntervalSince1970: 240))

        // Open session: no end, last screenshot at 520 -> 20s span from start 500.
        let openID = try uuid("00000000-0000-0000-0000-0000000000F1")
        try await client.openSession(CaptureSession(
            id: openID, bundleIdentifier: bundleID, displayName: "Art App",
            processIdentifier: 2, startedAt: Date(timeIntervalSince1970: 500)
        ))
        let openWindow = try uuid("00000000-0000-0000-0000-0000000000F2")
        try await client.upsertWindow(MonitoredWindow(
            id: openWindow, sessionID: openID, systemWindowID: 2, displayNumber: 1,
            label: nil, firstSeenAt: Date(timeIntervalSince1970: 500), lastSeenAt: Date(timeIntervalSince1970: 520)
        ))
        try await client.recordScreenshot(ScreenshotRecord(
            id: UUID(), windowID: openWindow, sessionID: openID,
            capturedAt: Date(timeIntervalSince1970: 520),
            fileURL: URL(filePath: "/tmp/o1.heic"), fileSizeBytes: 10
        ))

        let apps = try await client.apps()
        let app = try XCTUnwrap(apps.first { $0.bundleIdentifier == bundleID })
        // 140 (ended span) + 20 (open session up to last screenshot) = 160.
        XCTAssertEqual(app.totalActiveDuration, 160, accuracy: 0.001)
    }
}
