import ComposableArchitecture
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

    func testStablePresentedGeometryReusesAccessibilitySnapshot() {
        let cache = AccessibilityWindowGeometryCache()
        let fetchCount = LockIsolated(0)
        let first = [
            PresentedWindowGeometry(systemWindowID: 1, size: CGSize(width: 1000, height: 800)),
            PresentedWindowGeometry(systemWindowID: 2, size: CGSize(width: 600, height: 400)),
        ]
        let second = [
            PresentedWindowGeometry(systemWindowID: 2, size: CGSize(width: 601, height: 399)),
            PresentedWindowGeometry(systemWindowID: 1, size: CGSize(width: 1000, height: 800)),
        ]

        let firstSizes = cache.realWindowSizes(pid: 42, presentedWindows: first) {
            fetchCount.withValue { $0 += 1 }
            return [CGSize(width: 1000, height: 800), CGSize(width: 600, height: 400)]
        }
        let secondSizes = cache.realWindowSizes(pid: 42, presentedWindows: second) {
            fetchCount.withValue { $0 += 1 }
            return [CGSize(width: 1, height: 1)]
        }

        XCTAssertEqual(firstSizes, secondSizes)
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testPresentedGeometryChangeRefreshesAccessibilitySnapshot() {
        let cache = AccessibilityWindowGeometryCache()
        let fetchCount = LockIsolated(0)
        let original = [
            PresentedWindowGeometry(systemWindowID: 1, size: CGSize(width: 1000, height: 800)),
        ]
        let resized = [
            PresentedWindowGeometry(systemWindowID: 1, size: CGSize(width: 1003, height: 800)),
        ]

        _ = cache.realWindowSizes(pid: 42, presentedWindows: original) {
            fetchCount.withValue { $0 += 1 }
            return [original[0].size]
        }
        let refreshed = cache.realWindowSizes(pid: 42, presentedWindows: resized) {
            fetchCount.withValue { $0 += 1 }
            return [resized[0].size]
        }

        XCTAssertEqual(refreshed, [resized[0].size])
        XCTAssertEqual(fetchCount.value, 2)
    }

    func testFailedAccessibilityInspectionIsRetried() {
        let cache = AccessibilityWindowGeometryCache()
        let fetchCount = LockIsolated(0)
        let windows = [
            PresentedWindowGeometry(systemWindowID: 1, size: CGSize(width: 1000, height: 800)),
        ]

        let missing = cache.realWindowSizes(pid: 42, presentedWindows: windows) {
            fetchCount.withValue { $0 += 1 }
            return nil
        }
        let recovered = cache.realWindowSizes(pid: 42, presentedWindows: windows) {
            fetchCount.withValue { $0 += 1 }
            return [windows[0].size]
        }

        XCTAssertNil(missing)
        XCTAssertEqual(recovered, [windows[0].size])
        XCTAssertEqual(fetchCount.value, 2)
    }
}
