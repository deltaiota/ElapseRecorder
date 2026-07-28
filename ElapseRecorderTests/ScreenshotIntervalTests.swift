@testable import ElapseRecorder
import Foundation
import XCTest

final class ScreenshotIntervalTests: XCTestCase {
    func testAverageUsesConsecutiveTimestampsWithinEachWindowRun() throws {
        let firstSession = UUID()
        let secondSession = UUID()
        let firstWindow = UUID()
        let secondWindow = UUID()
        let records = [
            record(sessionID: firstSession, windowID: firstWindow, time: 0),
            record(sessionID: firstSession, windowID: firstWindow, time: 1),
            record(sessionID: firstSession, windowID: firstWindow, time: 4),
            record(sessionID: secondSession, windowID: secondWindow, time: 100),
            record(sessionID: secondSession, windowID: secondWindow, time: 102),
        ]

        // Intervals are 1, 3, and 2 seconds. The 96-second gap between sessions is excluded.
        XCTAssertEqual(try XCTUnwrap(ScreenshotInterval.average(records: records)), 2, accuracy: 0.0001)
    }

    func testAverageRemainsAvailableForCompactedFrames() throws {
        let sessionID = UUID()
        let windowID = UUID()
        let videoURL = URL(filePath: "/tmp/window.mov")
        let records = [0.0, 1.5, 4.0].enumerated().map { index, time in
            record(
                sessionID: sessionID,
                windowID: windowID,
                time: time,
                videoURL: videoURL,
                videoFrameIndex: index
            )
        }

        XCTAssertTrue(records.allSatisfy(\.isCompacted))
        XCTAssertEqual(try XCTUnwrap(ScreenshotInterval.average(records: records)), 2, accuracy: 0.0001)
    }

    func testAverageNeedsAtLeastTwoFramesFromOneWindowRun() {
        XCTAssertNil(ScreenshotInterval.average(records: []))
        XCTAssertNil(ScreenshotInterval.average(records: [
            record(sessionID: UUID(), windowID: UUID(), time: 0),
            record(sessionID: UUID(), windowID: UUID(), time: 10),
        ]))
    }

    private func record(
        sessionID: UUID,
        windowID: UUID,
        time: TimeInterval,
        videoURL: URL? = nil,
        videoFrameIndex: Int? = nil
    ) -> ScreenshotRecord {
        ScreenshotRecord(
            id: UUID(),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: time),
            fileURL: URL(filePath: "/tmp/frame.heic"),
            fileSizeBytes: 1,
            videoURL: videoURL,
            videoFrameIndex: videoFrameIndex
        )
    }
}
