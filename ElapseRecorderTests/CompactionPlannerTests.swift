@testable import ElapseRecorder
import XCTest

final class CompactionPlannerTests: XCTestCase {
    private func frame(_ id: UUID = UUID(), at seconds: TimeInterval, w: Int = 2560, h: Int = 1440) -> CompactableFrame {
        CompactableFrame(
            id: id,
            sourceURL: URL(filePath: "/tmp/\(id).heic"),
            pixelWidth: w,
            pixelHeight: h,
            capturedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    func testOrdersFramesByCaptureTime() throws {
        let a = frame(at: 30), b = frame(at: 10), c = frame(at: 20)
        let plan = CompactionPlanner.plan(
            sessionID: UUID(),
            sessionDirectory: URL(filePath: "/captures/session"),
            windows: [.init(windowID: UUID(), displayNumber: 1,
                            frames: [a, b, c] + (0 ..< 5).map { frame(at: 40 + Double($0)) })]
        )
        let window = try XCTUnwrap(plan.windows.first)
        XCTAssertEqual(window.frames.prefix(3).map(\.id), [b.id, c.id, a.id])
    }

    func testSkipsWindowsBelowMinimumFrameCount() {
        let plan = CompactionPlanner.plan(
            sessionID: UUID(),
            sessionDirectory: URL(filePath: "/captures/session"),
            windows: [.init(windowID: UUID(), displayNumber: 1,
                            frames: (0 ..< 3).map { frame(at: Double($0)) })]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testCanvasIsMaxEvenDimensionsAcrossFrames() throws {
        let frames = [frame(at: 1, w: 2560, h: 1440), frame(at: 2, w: 2561, h: 1441)]
            + (0 ..< 6).map { frame(at: 10 + Double($0), w: 2000, h: 1000) }
        let plan = CompactionPlanner.plan(
            sessionID: UUID(),
            sessionDirectory: URL(filePath: "/captures/session"),
            windows: [.init(windowID: UUID(), displayNumber: 2, frames: frames)]
        )
        let window = try XCTUnwrap(plan.windows.first)
        XCTAssertEqual(window.canvasWidth, 2560) // 2561 -> even 2560
        XCTAssertEqual(window.canvasHeight, 1440) // 1441 -> even 1440
        XCTAssertEqual(window.outputURL.lastPathComponent, "window-2.mov")
    }

    func testZeroDimensionsDeferCanvasToEncodeTime() throws {
        let frames = (0 ..< 8).map { frame(at: Double($0), w: 0, h: 0) }
        let plan = CompactionPlanner.plan(
            sessionID: UUID(),
            sessionDirectory: URL(filePath: "/captures/session"),
            windows: [.init(windowID: UUID(), displayNumber: 1, frames: frames)]
        )
        let window = try XCTUnwrap(plan.windows.first)
        XCTAssertEqual(window.canvasWidth, 0)
        XCTAssertEqual(window.canvasHeight, 0)
        XCTAssertEqual(window.frames.count, 8)
    }

    func testEmptyWhenNoWindows() {
        let plan = CompactionPlanner.plan(
            sessionID: UUID(),
            sessionDirectory: URL(filePath: "/captures/session"),
            windows: []
        )
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.totalFrameCount, 0)
    }
}
