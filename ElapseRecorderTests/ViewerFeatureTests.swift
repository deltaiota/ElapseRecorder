import ComposableArchitecture
@testable import ElapseRecorder
import Foundation
import XCTest

final class ViewerFeatureTests: XCTestCase {
    @MainActor
    func testExportTimelapseChoosesDestinationEncodesAndReveals() async {
        let urls = [URL(filePath: "/tmp/a.heic"), URL(filePath: "/tmp/b.heic")]
        let destination = URL(filePath: "/tmp/out.mp4")
        let revealed = LockIsolated<URL?>(nil)

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.exportPanelClient.present = { _, _ in
                ExportSelection(
                    destinationURL: destination,
                    options: ExportOptions(codec: .hevc, container: .mov, framesPerSecond: 24, interpolationFrames: 3)
                )
            }
            $0.timelapseExportClient.export = { request in
                AsyncThrowingStream { continuation in
                    XCTAssertEqual(request.imageURLs, urls)
                    XCTAssertEqual(request.destinationURL, destination)
                    XCTAssertEqual(request.codec, .hevc)
                    XCTAssertEqual(request.container, .mov)
                    XCTAssertEqual(request.framesPerSecond, 24)
                    XCTAssertEqual(request.interpolationFrames, 3)
                    continuation.yield(0.5)
                    continuation.yield(1.0)
                    continuation.finish()
                }
            }
            $0.fileRevealClient.reveal = { url in revealed.setValue(url) }
        }

        await store.send(.exportTimelapseRequested(urls: urls)) {
            $0.exportProgress = 0
        }
        await store.receive(\.exportProgressed) {
            $0.exportProgress = 0.5
        }
        await store.receive(\.exportProgressed) {
            $0.exportProgress = 1.0
        }
        await store.receive(\.exportCompleted) {
            $0.exportProgress = nil
        }
        XCTAssertEqual(revealed.value, destination)
    }

    @MainActor
    func testExportTimelapseCancelledWhenNoDestinationChosen() async {
        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.exportPanelClient.present = { _, _ in nil }
            $0.fileRevealClient.reveal = { _ in }
        }

        await store.send(.exportTimelapseRequested(urls: [URL(filePath: "/tmp/a.heic")])) {
            $0.exportProgress = 0
        }
        await store.receive(\.exportCancelled) {
            $0.exportProgress = nil
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
            $0.persistenceClient.timelineForWindow = { _, _ in [.screenshot(windowScreenshot)] }
        }

        // Selecting a window (e.g. tapping its lane) loads that window's screenshots.
        await store.send(.windowPickerSelectionChanged(.window(id: windowID))) {
            $0.selectedWindowID = windowID
            $0.windowTimelineEntries = []
            $0.isShowingFlatGallery = false
            $0.isLoading = true
        }
        await store.receive(.timelineEntriesLoaded([.screenshot(windowScreenshot)])) {
            $0.windowTimelineEntries = [.screenshot(windowScreenshot)]
            $0.isLoading = false
        }
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
            $0.persistenceClient.timelineForWindow = { _, _ in
                [.screenshot(inRange), .screenshot(outOfRange)]
            }
        }

        await store.send(.windowSegmentSelected(windowID: windowID, segment: segment)) {
            $0.selectedWindowID = windowID
            $0.selectedSegment = segment
            $0.windowTimelineEntries = []
            $0.isShowingFlatGallery = false
            $0.isLoading = true
        }
        // Only the screenshot inside the segment's [150, 200] range survives the filter.
        await store.receive(.timelineEntriesLoaded([.screenshot(inRange)])) {
            $0.windowTimelineEntries = [.screenshot(inRange)]
            $0.isLoading = false
        }
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

    @MainActor
    func testDeleteSelectedEndedSessionDeletesFilesAndMetadataThenRefreshes() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000501"))
        let session = CaptureSessionSummary(
            id: sessionID,
            bundleIdentifier: "com.example.DeleteApp",
            displayName: "Delete App",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            windowCount: 1,
            screenshotCount: 2
        )
        let deletedFileSessions = LockIsolated([(String, UUID)]())
        let deletedMetadataSessions = LockIsolated([UUID]())

        var state = ViewerFeature.State()
        state.apps = [
            AppCaptureSummary(
                bundleIdentifier: session.bundleIdentifier,
                displayName: session.displayName,
                sessionCount: 1,
                screenshotCount: 2,
                lastCapturedAt: Date(timeIntervalSince1970: 150)
            ),
        ]
        state.sessions = [session]
        state.selectedBundleIdentifier = session.bundleIdentifier
        state.selectedSessionID = session.id

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.fileStorageClient.deleteSessionCaptures = { bundleIdentifier, sessionID in
                deletedFileSessions.withValue { $0.append((bundleIdentifier, sessionID)) }
            }
            $0.persistenceClient.deleteSession = { sessionID in
                deletedMetadataSessions.withValue { $0.append(sessionID) }
            }
            $0.persistenceClient.apps = { [] }
            $0.persistenceClient.sessions = { _ in [] }
            $0.persistenceClient.windows = { _ in [] }
            $0.persistenceClient.timelineForApp = { _ in [] }
            $0.persistenceClient.timelineForSession = { _ in [] }
            $0.persistenceClient.timelineForWindow = { _, _ in [] }
        }
        store.exhaustivity = .off

        await store.send(.deleteSelectedSessionButtonTapped) {
            $0.isLoading = true
        }
        await store.receive(.sessionDeleted(session.id)) {
            $0.selectedSessionID = nil
            $0.windows = []
            $0.windowTimelineEntries = []
            $0.isLoading = false
        }

        XCTAssertEqual(deletedFileSessions.value.map(\.0), [session.bundleIdentifier])
        XCTAssertEqual(deletedFileSessions.value.map(\.1), [session.id])
        XCTAssertEqual(deletedMetadataSessions.value, [session.id])
    }

    @MainActor
    func testDeleteSpecificUnselectedEndedSessionKeepsCurrentSelection() async throws {
        let selectedSessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000503"))
        let deletedSessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000504"))
        let selectedSession = CaptureSessionSummary(
            id: selectedSessionID,
            bundleIdentifier: "com.example.DeleteApp",
            displayName: "Delete App",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            windowCount: 1,
            screenshotCount: 2
        )
        let deletedSession = CaptureSessionSummary(
            id: deletedSessionID,
            bundleIdentifier: "com.example.DeleteApp",
            displayName: "Delete App",
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 400),
            windowCount: 1,
            screenshotCount: 2
        )
        let deletedFileSessions = LockIsolated([(String, UUID)]())
        let deletedMetadataSessions = LockIsolated([UUID]())

        var state = ViewerFeature.State()
        state.sessions = [selectedSession, deletedSession]
        state.selectedBundleIdentifier = selectedSession.bundleIdentifier
        state.selectedSessionID = selectedSession.id

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.fileStorageClient.deleteSessionCaptures = { bundleIdentifier, sessionID in
                deletedFileSessions.withValue { $0.append((bundleIdentifier, sessionID)) }
            }
            $0.persistenceClient.deleteSession = { sessionID in
                deletedMetadataSessions.withValue { $0.append(sessionID) }
            }
            $0.persistenceClient.apps = { [] }
            $0.persistenceClient.sessions = { _ in [] }
            $0.persistenceClient.windows = { _ in [] }
            $0.persistenceClient.timelineForApp = { _ in [] }
            $0.persistenceClient.timelineForSession = { _ in [] }
            $0.persistenceClient.timelineForWindow = { _, _ in [] }
        }
        store.exhaustivity = .off

        await store.send(.deleteSessionButtonTapped(deletedSession)) {
            $0.isLoading = true
        }
        await store.receive(.sessionDeleted(deletedSession.id)) {
            $0.isLoading = false
        }

        XCTAssertEqual(deletedFileSessions.value.map(\.0), [deletedSession.bundleIdentifier])
        XCTAssertEqual(deletedFileSessions.value.map(\.1), [deletedSession.id])
        XCTAssertEqual(deletedMetadataSessions.value, [deletedSession.id])
    }

    @MainActor
    func testDeleteSelectedOpenSessionIsBlocked() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000502"))
        let session = CaptureSessionSummary(
            id: sessionID,
            bundleIdentifier: "com.example.ActiveApp",
            displayName: "Active App",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            windowCount: 1,
            screenshotCount: 2
        )
        var state = ViewerFeature.State()
        state.sessions = [session]
        state.selectedBundleIdentifier = session.bundleIdentifier
        state.selectedSessionID = session.id

        let store = TestStore(initialState: state) {
            ViewerFeature()
        }

        await store.send(.deleteSelectedSessionButtonTapped) {
            $0.errorMessage = "Stop capture before deleting an active session."
        }
    }
}
