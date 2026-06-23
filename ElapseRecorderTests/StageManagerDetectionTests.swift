import CoreGraphics
@testable import ElapseRecorder
import XCTest

final class StageManagerDetectionTests: XCTestCase {
    func testStowedWindowIsNotCapturable() {
        let stowed = CapturableWindow(
            systemWindowID: 1,
            title: "Doc",
            frame: CGRect(x: 16, y: 903, width: 85, height: 99),
            layer: 0,
            isOnScreen: true,
            isStageManagerStowed: true
        )
        XCTAssertFalse(stowed.shouldCapture)
    }

    func testVisibleWindowIsCapturable() {
        let visible = CapturableWindow(
            systemWindowID: 1,
            title: "Doc",
            frame: CGRect(x: 376, y: 121, width: 586, height: 476),
            layer: 0,
            isOnScreen: true,
            isStageManagerStowed: false
        )
        XCTAssertTrue(visible.shouldCapture)
    }

    func testPresentedSizeMatchesRealSizeWhenVisible() {
        // Visible: ScreenCaptureKit frame equals the Accessibility size → not stowed.
        let matches = AccessibilityWindowInspector.size(
            CGSize(width: 586, height: 476),
            matchesAnyOf: [CGSize(width: 586, height: 476)]
        )
        XCTAssertTrue(matches)
    }

    func testThumbnailSizeMatchesNoRealSizeWhenStowed() {
        // Stowed: the thumbnail size matches none of the app's real Accessibility sizes.
        let matches = AccessibilityWindowInspector.size(
            CGSize(width: 85, height: 99),
            matchesAnyOf: [CGSize(width: 586, height: 476)]
        )
        XCTAssertFalse(matches)
    }

    func testSizeMatchingToleratesSubPixelRounding() {
        let matches = AccessibilityWindowInspector.size(
            CGSize(width: 585.6, height: 476.4),
            matchesAnyOf: [CGSize(width: 586, height: 476)]
        )
        XCTAssertTrue(matches)
    }

    func testSizeMatchesAnyOfMultipleRealWindows() {
        let realSizes = [CGSize(width: 586, height: 476), CGSize(width: 800, height: 600)]
        XCTAssertTrue(AccessibilityWindowInspector.size(CGSize(width: 800, height: 600), matchesAnyOf: realSizes))
        XCTAssertFalse(AccessibilityWindowInspector.size(CGSize(width: 85, height: 99), matchesAnyOf: realSizes))
    }
}
