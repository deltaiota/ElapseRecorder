@testable import ElapseRecorder
import Foundation
import XCTest

final class CaptureSessionSummaryTests: XCTestCase {
    func testStorageStateDistinguishesStandaloneMixedAndCompactedSessions() {
        XCTAssertEqual(summary(screenshotCount: 10, compactedCount: 0).storageState, .uncompacted)
        XCTAssertEqual(summary(screenshotCount: 10, compactedCount: 9).storageState, .partiallyCompacted)
        XCTAssertEqual(summary(screenshotCount: 10, compactedCount: 10).storageState, .compacted)
        XCTAssertEqual(summary(screenshotCount: 0, compactedCount: 0).storageState, .uncompacted)
    }

    func testIsCompactedRequiresEveryScreenshotToBeVideoBacked() {
        XCTAssertFalse(summary(screenshotCount: 10, compactedCount: 0).isCompacted)
        XCTAssertFalse(summary(screenshotCount: 10, compactedCount: 9).isCompacted)
        XCTAssertTrue(summary(screenshotCount: 10, compactedCount: 10).isCompacted)
    }

    private func summary(
        screenshotCount: Int,
        compactedCount: Int
    ) -> CaptureSessionSummary {
        CaptureSessionSummary(
            id: UUID(),
            bundleIdentifier: "com.example.App",
            displayName: "App",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 10),
            windowCount: 1,
            screenshotCount: screenshotCount,
            compactedScreenshotCount: compactedCount
        )
    }
}
