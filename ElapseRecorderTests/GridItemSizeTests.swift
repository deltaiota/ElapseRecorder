@testable import ElapseRecorder
import XCTest

final class GridItemSizeTests: XCTestCase {
    func testInitClampsToBounds() {
        XCTAssertEqual(GridItemSize(0).value, GridItemSize.minimum)
        XCTAssertEqual(GridItemSize(10000).value, GridItemSize.maximum)
        XCTAssertEqual(GridItemSize(200).value, 200)
    }

    func testAdditionNeverExceedsMaximum() {
        let size = GridItemSize(GridItemSize.maximum)
        XCTAssertEqual((size + 1000).value, GridItemSize.maximum)
        XCTAssertTrue((size + 1000).isAtMaximum)
    }

    func testSubtractionNeverGoesBelowMinimum() {
        let size = GridItemSize(GridItemSize.minimum)
        XCTAssertEqual((size - 1000).value, GridItemSize.minimum)
        XCTAssertTrue((size - 1000).isAtMinimum)
    }

    func testSteppingStaysWithinBoundsAcrossManySteps() {
        var size = GridItemSize.default
        for _ in 0 ..< 100 {
            size = size.steppedUp()
        }
        XCTAssertEqual(size.value, GridItemSize.maximum)

        for _ in 0 ..< 100 {
            size = size.steppedDown()
        }
        XCTAssertEqual(size.value, GridItemSize.minimum)
    }

    func testRawValueRoundTripsAndClampsOnDecode() {
        let size = GridItemSize(240)
        XCTAssertEqual(size.rawValue, 240)
        XCTAssertEqual(GridItemSize(rawValue: 240), size)

        // A persisted value outside the range is pulled back in on load.
        XCTAssertEqual(GridItemSize(rawValue: 5)?.value, GridItemSize.minimum)
        XCTAssertEqual(GridItemSize(rawValue: 9999)?.value, GridItemSize.maximum)
    }
}
