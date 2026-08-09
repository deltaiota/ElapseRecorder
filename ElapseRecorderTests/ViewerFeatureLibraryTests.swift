import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class ViewerFeatureLibraryTests: XCTestCase {
    @MainActor
    func testCaptureScreenshotUpdatesVisibleStateIncrementally() async {
        let bundleIdentifier = "com.example.ArtApp"
        let sessionID = UUID()
        let windowID = UUID()
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let previousCapture = Date(timeIntervalSince1970: 110)
        let capturedAt = Date(timeIntervalSince1970: 112)
        let record = ScreenshotRecord(
            id: UUID(),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: capturedAt,
            fileURL: URL(filePath: "/tmp/frame.heic"),
            fileSizeBytes: 5
        )

        var state = ViewerFeature.State()
        state.apps = [
            AppCaptureSummary(
                bundleIdentifier: bundleIdentifier,
                displayName: "Art App",
                sessionCount: 1,
                screenshotCount: 10,
                lastCapturedAt: previousCapture,
                sizeBytes: 100,
                totalActiveDuration: 10
            ),
        ]
        state.sessions = [
            CaptureSessionSummary(
                id: sessionID,
                bundleIdentifier: bundleIdentifier,
                displayName: "Art App",
                startedAt: startedAt,
                endedAt: nil,
                windowCount: 1,
                screenshotCount: 10,
                sizeBytes: 100
            ),
        ]
        state.windows = [
            WindowCaptureSummary(
                id: windowID,
                displayNumber: 1,
                label: "Canvas",
                firstSeenAt: startedAt,
                lastSeenAt: previousCapture,
                screenshotCount: 10
            ),
        ]
        state.selectedBundleIdentifier = bundleIdentifier
        state.selectedSessionID = sessionID
        state.selectedWindowID = windowID
        state.sessionTimeline = SessionTimeline(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: nil,
            lanes: [
                WindowLane(
                    windowID: windowID,
                    displayNumber: 1,
                    systemWindowID: 1,
                    bornAt: startedAt,
                    diedAt: previousCapture,
                    segments: [
                        WindowTitleSegment(
                            id: segmentID,
                            title: "Canvas",
                            startedAt: startedAt,
                            endedAt: Date(timeIntervalSince1970: 200),
                            screenshotCount: 10
                        ),
                    ],
                    screenshotCount: 10
                ),
            ],
            unavailableSpans: []
        )

        let store = TestStore(initialState: state) {
            ViewerFeature()
        }

        await store.send(.captureScreenshotRecorded(record, bundleIdentifier: bundleIdentifier)) {
            $0.apps[0].screenshotCount = 11
            $0.apps[0].lastCapturedAt = capturedAt
            $0.apps[0].sizeBytes = 105
            $0.apps[0].totalActiveDuration = 12
            $0.sessions[0].screenshotCount = 11
            $0.sessions[0].sizeBytes = 105
            $0.windows[0].screenshotCount = 11
            $0.windowTimelineEntries = [.screenshot(record)]
            $0.sessionTimeline?.lanes[0].diedAt = capturedAt
            $0.sessionTimeline?.lanes[0].segments[0].screenshotCount = 11
            $0.sessionTimeline?.lanes[0].screenshotCount = 11
        }
    }

    @MainActor
    func testSelectingSessionLoadsWindowsAndTimelineGraph() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000601"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000602"))
        let window = WindowCaptureSummary(
            id: windowID,
            displayNumber: 1,
            label: "Canvas",
            firstSeenAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 200),
            screenshotCount: 1
        )
        let timeline = SessionTimeline(
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            lanes: [
                WindowLane(
                    windowID: windowID,
                    displayNumber: 1,
                    systemWindowID: 5,
                    bornAt: Date(timeIntervalSince1970: 100),
                    diedAt: Date(timeIntervalSince1970: 200),
                    segments: [
                        WindowTitleSegment(
                            id: windowID,
                            title: "Canvas",
                            startedAt: Date(timeIntervalSince1970: 100),
                            endedAt: Date(timeIntervalSince1970: 200),
                            screenshotCount: 1
                        ),
                    ],
                    screenshotCount: 1
                ),
            ],
            unavailableSpans: []
        )
        var state = ViewerFeature.State()
        state.selectedBundleIdentifier = "com.example.ArtApp"

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.windows = { _ in [window] }
            $0.persistenceClient.sessionTimeline = { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
                return timeline
            }
        }

        await store.send(.sessionSelected(sessionID)) {
            $0.selectedSessionID = sessionID
            $0.isLoading = true
        }
        await store.receive(.windowsLoaded([window])) {
            $0.windows = [window]
            $0.isLoading = false
        }
        await store.receive(.sessionTimelineLoaded(timeline)) {
            $0.sessionTimeline = timeline
        }
        XCTAssertTrue(store.state.isShowingTimelineGraph)
        XCTAssertEqual(store.state.windowPickerSelection, .all)
    }

    @MainActor
    func testLiveFrameUpdatesPagedCountAndLaterPageDoesNotDuplicate() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000680"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000681"))
        let existing = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000682")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 1),
            fileURL: URL(filePath: "/tmp/existing.heic"),
            fileSizeBytes: 10
        )
        let live = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000683")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 2),
            fileURL: URL(filePath: "/tmp/live.heic"),
            fileSizeBytes: 10
        )
        let query = FrameQuery(scope: .window(sessionID: sessionID, windowID: windowID))
        var state = ViewerFeature.State()
        state.selectedBundleIdentifier = "com.example.App"
        state.selectedSessionID = sessionID
        state.sessions = [CaptureSessionSummary(
            id: sessionID,
            bundleIdentifier: "com.example.App",
            displayName: "App",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: nil,
            windowCount: 1,
            screenshotCount: 1
        )]
        state.windows = [WindowCaptureSummary(
            id: windowID,
            displayNumber: 1,
            label: nil,
            firstSeenAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 1),
            screenshotCount: 1
        )]
        state.selectedWindowID = windowID
        state.frameQuery = query
        state.windowTimelineEntries = [.screenshot(existing)]
        state.frameTotalCount = 1

        let store = TestStore(initialState: state) { ViewerFeature() }
        store.exhaustivity = .off
        await store.send(.captureScreenshotRecorded(live, bundleIdentifier: "com.example.App"))
        XCTAssertEqual(store.state.frameTotalCount, 2)
        XCTAssertEqual(store.state.windowTimelineEntries.map(\.id), [existing.id, live.id])

        await store.send(.framePageLoaded(
            query: query,
            page: FramePage(frames: [live], nextCursor: nil, totalCount: 2),
            appending: true
        ))
        XCTAssertEqual(store.state.windowTimelineEntries.map(\.id), [existing.id, live.id])
    }

    @MainActor
    func testSelectingWindowThenReturningToTimeline() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000604"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000605"))
        let windowScreenshot = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000607")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 175),
            fileURL: URL(filePath: "/tmp/window.heic"),
            fileSizeBytes: 2048
        )
        var state = ViewerFeature.State()
        state.selectedSessionID = sessionID

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.framePage = { query, _, _ in
                XCTAssertEqual(query, FrameQuery(scope: .window(sessionID: sessionID, windowID: windowID)))
                return FramePage(frames: [windowScreenshot], nextCursor: nil, totalCount: 1)
            }
        }
        store.exhaustivity = .off

        await store.send(.windowPickerSelectionChanged(.window(id: windowID)))
        await store.skipReceivedActions()
        XCTAssertEqual(store.state.windowTimelineEntries, [.screenshot(windowScreenshot)])
        XCTAssertEqual(store.state.frameTotalCount, 1)
        XCTAssertFalse(store.state.isShowingTimelineGraph)

        // Clearing the window selection returns to the timeline graph without loading a grid.
        await store.send(.windowPickerSelectionChanged(.all)) {
            $0.selectedWindowID = nil
            $0.windowTimelineEntries = []
        }
        XCTAssertTrue(store.state.isShowingTimelineGraph)
    }

    @MainActor
    func testSelectingWindowSegmentFiltersGridToSegmentRange() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000620"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000621"))
        let inRange = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000622")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 160),
            fileURL: URL(filePath: "/tmp/in.heic"),
            fileSizeBytes: 10
        )
        let outOfRange = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000623")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 260),
            fileURL: URL(filePath: "/tmp/out.heic"),
            fileSizeBytes: 10
        )
        let segment = try WindowTitleSegment(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000624")),
            title: "Untitled",
            startedAt: Date(timeIntervalSince1970: 150),
            endedAt: Date(timeIntervalSince1970: 200),
            screenshotCount: 1
        )
        var state = ViewerFeature.State()
        state.selectedSessionID = sessionID

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.framePage = { query, _, _ in
                XCTAssertEqual(
                    query,
                    FrameQuery(
                        scope: .window(sessionID: sessionID, windowID: windowID),
                        capturedAt: segment.startedAt ... segment.endedAt
                    )
                )
                return FramePage(frames: [inRange], nextCursor: nil, totalCount: 1)
            }
        }
        store.exhaustivity = .off

        await store.send(.windowSegmentSelected(windowID: windowID, segment: segment))
        await store.skipReceivedActions()
        XCTAssertEqual(store.state.windowTimelineEntries, [.screenshot(inRange)])
        XCTAssertFalse(store.state.windowTimelineEntries.contains(.screenshot(outOfRange)))
    }

    @MainActor
    func testWindowPickerSelectingCurrentItemDoesNotReloadScreenshots() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000608"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000609"))
        var state = ViewerFeature.State()
        state.selectedSessionID = sessionID
        state.selectedWindowID = windowID

        let windowTimelineLoadCount = LockIsolated(0)
        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.timelineForWindow = { _, _ in
                windowTimelineLoadCount.withValue { $0 += 1 }
                return []
            }
        }

        // Re-selecting the current window is a no-op.
        await store.send(.windowPickerSelectionChanged(.window(id: windowID)))
        XCTAssertEqual(windowTimelineLoadCount.value, 0)

        // Returning to the timeline graph loads no grid.
        await store.send(.windowPickerSelectionChanged(.all)) {
            $0.selectedWindowID = nil
        }
        XCTAssertEqual(windowTimelineLoadCount.value, 0)
        XCTAssertTrue(store.state.isShowingTimelineGraph)

        // Already on the timeline graph; selecting "all" again is a no-op.
        await store.send(.windowPickerSelectionChanged(.all))
        XCTAssertEqual(windowTimelineLoadCount.value, 0)
    }
}
