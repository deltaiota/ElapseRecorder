@testable import ElapseRecorder
import Foundation
import SwiftData
import XCTest

final class CompactionPersistenceTests: XCTestCase {
    @MainActor
    func testCompactionPlanThenApplyRepointsFramesAndApportionsSize() async throws {
        let client = try PersistenceClient.live(modelContainer: inMemoryContainer())
        let sessionID = try uuid("00000000-0000-0000-0000-0000000000A1")
        let windowID = try uuid("00000000-0000-0000-0000-0000000000B1")

        let session = try CaptureSession(
            id: sessionID,
            bundleIdentifier: "com.example.ArtApp",
            displayName: "Art App",
            processIdentifier: 101,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try await client.openSession(session)
        try await client.upsertWindow(
            MonitoredWindow(
                id: windowID,
                sessionID: sessionID,
                systemWindowID: 501,
                displayNumber: 1,
                label: "Canvas",
                firstSeenAt: Date(timeIntervalSince1970: 100),
                lastSeenAt: Date(timeIntervalSince1970: 200)
            )
        )

        let base = "/tmp/captures/com.example.ArtApp/\(sessionID.uuidString)/window-1"
        // Record 10 frames out of chronological order to exercise plan ordering.
        var recordIDs: [UUID] = []
        for offset in [5, 1, 9, 3, 7, 2, 8, 4, 6, 0] {
            let id = UUID()
            recordIDs.append(id)
            try await client.recordScreenshot(
                ScreenshotRecord(
                    id: id,
                    windowID: windowID,
                    sessionID: sessionID,
                    capturedAt: Date(timeIntervalSince1970: 100 + Double(offset)),
                    fileURL: URL(filePath: "\(base)/\(100 + offset).heic"),
                    fileSizeBytes: 400,
                    pixelWidth: 2560,
                    pixelHeight: 1440
                )
            )
        }
        try await client.closeSession(sessionID, Date(timeIntervalSince1970: 300))

        // Plan: one window, 10 frames ordered by capturedAt, correct output path + canvas.
        let plan = try await client.compactionPlanForSession(sessionID)
        let window = try XCTUnwrap(plan?.windows.first)
        XCTAssertEqual(plan?.windows.count, 1)
        XCTAssertEqual(window.frames.count, 10)
        XCTAssertEqual(window.canvasWidth, 2560)
        XCTAssertEqual(window.canvasHeight, 1440)
        XCTAssertEqual(window.outputURL.lastPathComponent, "window-1.mov")
        XCTAssertEqual(
            window.outputURL.deletingLastPathComponent().lastPathComponent,
            sessionID.uuidString
        )
        let capturedTimes = window.frames.map(\.capturedAt)
        XCTAssertEqual(capturedTimes, capturedTimes.sorted())

        // Apply: repoint each frame to the video with its index and apportion the byte size.
        let videoPath = window.outputURL.path(percentEncoded: false)
        try await client.applyCompaction(
            windowID,
            videoPath,
            window.frames.map(\.id),
            1005
        )

        let frames = try await client.screenshotsForWindow(windowID)
        XCTAssertEqual(frames.count, 10)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.videoURL, URL(filePath: videoPath))
            XCTAssertEqual(frame.videoFrameIndex, index)
            XCTAssertTrue(frame.isCompacted)
            XCTAssertEqual(frame.capturedAt, Date(timeIntervalSince1970: 100 + Double(index)))
        }
        // Apportioned sizes sum exactly to the video size.
        XCTAssertEqual(frames.reduce(0) { $0 + $1.fileSizeBytes }, 1005)

        // Integrity sweep sees the video path (never the deleted originals), so compacted
        // records are not mistaken for missing and the video is not treated as an orphan.
        let fileIndex = try await client.screenshotFileIndex()
        XCTAssertEqual(fileIndex.count, 10)
        XCTAssertTrue(fileIndex.allSatisfy { $0.path == videoPath })

        // Deletion collapses the shared video into a single path.
        let deletionPaths = try await client.screenshotPathsForSession(sessionID)
        XCTAssertEqual(deletionPaths, [videoPath])

        // A fully compacted session yields no further plan.
        let planAfter = try await client.compactionPlanForSession(sessionID)
        XCTAssertNil(planAfter)
    }

    @MainActor
    func testOpenSessionIsNeverCompacted() async throws {
        let client = try PersistenceClient.live(modelContainer: inMemoryContainer())
        let sessionID = try uuid("00000000-0000-0000-0000-0000000000C1")
        let windowID = try uuid("00000000-0000-0000-0000-0000000000D1")

        try await client.openSession(
            CaptureSession(
                id: sessionID,
                bundleIdentifier: "com.example.ArtApp",
                displayName: "Art App",
                processIdentifier: 1,
                startedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try await client.upsertWindow(
            MonitoredWindow(
                id: windowID,
                sessionID: sessionID,
                systemWindowID: 1,
                displayNumber: 1,
                label: nil,
                firstSeenAt: Date(timeIntervalSince1970: 100),
                lastSeenAt: Date(timeIntervalSince1970: 100)
            )
        )
        for index in 0 ..< 10 {
            try await client.recordScreenshot(
                ScreenshotRecord(
                    id: UUID(),
                    windowID: windowID,
                    sessionID: sessionID,
                    capturedAt: Date(timeIntervalSince1970: 100 + Double(index)),
                    fileURL: URL(filePath: "/tmp/captures/app/\(sessionID.uuidString)/window-1/\(index).heic"),
                    fileSizeBytes: 100,
                    pixelWidth: 100,
                    pixelHeight: 100
                )
            )
        }

        // Session is still open (never closed) -> must not be a compaction candidate.
        let plan = try await client.compactionPlanForSession(sessionID)
        XCTAssertNil(plan)
    }

    private func inMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Schema.elapseRecorder, configurations: [configuration])
    }

    private func uuid(_ string: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: string))
    }
}
