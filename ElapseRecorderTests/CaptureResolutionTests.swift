@testable import ElapseRecorder
import XCTest

final class CaptureResolutionTests: XCTestCase {
    func testCapScalesDownPreservingAspectRatio() {
        // A 6016×3384 (≈20 MP) Retina editor window capped to 2560 long edge.
        let size = CaptureResolution.cappedPixelSize(width: 6016, height: 3384, maxDimension: 2560)
        XCTAssertEqual(size.width, 2560)
        // 3384 * (2560/6016) = 1440.0
        XCTAssertEqual(size.height, 1440)
    }

    func testCapUsesLongestEdgeForPortraitWindows() {
        let size = CaptureResolution.cappedPixelSize(width: 1200, height: 3000, maxDimension: 1500)
        XCTAssertEqual(size.height, 1500)
        XCTAssertEqual(size.width, 600)
    }

    func testNoCapWhenAlreadyWithinLimit() {
        let size = CaptureResolution.cappedPixelSize(width: 1920, height: 1080, maxDimension: 2560)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    func testZeroOrNegativeMaxMeansNativeResolution() {
        let native = CaptureResolution.cappedPixelSize(width: 6016, height: 3384, maxDimension: 0)
        XCTAssertEqual(native.width, 6016)
        XCTAssertEqual(native.height, 3384)

        let negative = CaptureResolution.cappedPixelSize(width: 6016, height: 3384, maxDimension: -100)
        XCTAssertEqual(negative.width, 6016)
        XCTAssertEqual(negative.height, 3384)
    }

    func testNeverUpscales() {
        let size = CaptureResolution.cappedPixelSize(width: 800, height: 600, maxDimension: 4000)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func testDegenerateSizesAreClampedToAtLeastOne() {
        let size = CaptureResolution.cappedPixelSize(width: 0, height: 0, maxDimension: 2560)
        XCTAssertGreaterThanOrEqual(size.width, 1)
        XCTAssertGreaterThanOrEqual(size.height, 1)
    }
}
