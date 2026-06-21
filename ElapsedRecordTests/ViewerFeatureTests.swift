import ComposableArchitecture
@testable import ElapsedRecord
import Foundation
import XCTest

final class ViewerFeatureTests: XCTestCase {
    @MainActor
    func testSelectingSessionDefaultsToAllWindowsAndLoadsSessionScreenshots() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000601"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000602"))
        let screenshotID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000603"))
        let window = WindowCaptureSummary(
            id: windowID,
            displayNumber: 1,
            label: "Canvas",
            firstSeenAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 200),
            screenshotCount: 1
        )
        let screenshot = ScreenshotRecord(
            id: screenshotID,
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 150),
            fileURL: URL(filePath: "/tmp/session.heic"),
            fileSizeBytes: 1024
        )
        var state = ViewerFeature.State()
        state.selectedBundleIdentifier = "com.example.ArtApp"

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.windows = { _ in [window] }
            $0.persistenceClient.timelineForSession = { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
                return [.screenshot(screenshot)]
            }
        }

        await store.send(.sessionSelected(sessionID)) {
            $0.selectedSessionID = sessionID
            $0.selectedWindowID = nil
            $0.windows = []
            $0.windowTimelineEntries = []
            $0.selectedScreenshot = nil
            $0.isShowingFlatGallery = false
            $0.isLoading = true
        }
        await store.receive(.windowsLoaded([window])) {
            $0.windows = [window]
            $0.isLoading = false
        }
        await store.receive(.timelineEntriesLoaded([.screenshot(screenshot)])) {
            $0.windowTimelineEntries = [.screenshot(screenshot)]
            $0.isLoading = false
        }
        XCTAssertEqual(store.state.windowPickerSelection, .all)
    }

    @MainActor
    func testWindowPickerSwitchesBetweenWindowAndAllScreenshots() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000604"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000605"))
        let allScreenshot = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000606")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 150),
            fileURL: URL(filePath: "/tmp/all.heic"),
            fileSizeBytes: 1024
        )
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
        state.windowTimelineEntries = [.screenshot(allScreenshot)]

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.timelineForWindow = { _, _ in [.screenshot(windowScreenshot)] }
            $0.persistenceClient.timelineForSession = { _ in [.screenshot(allScreenshot)] }
        }

        await store.send(.windowPickerSelectionChanged(.window(id: windowID))) {
            $0.selectedWindowID = windowID
            $0.windowTimelineEntries = []
            $0.selectedScreenshot = nil
            $0.isShowingFlatGallery = false
            $0.isLoading = true
        }
        await store.receive(.timelineEntriesLoaded([.screenshot(windowScreenshot)])) {
            $0.windowTimelineEntries = [.screenshot(windowScreenshot)]
            $0.isLoading = false
        }

        await store.send(.windowPickerSelectionChanged(.all)) {
            $0.selectedWindowID = nil
            $0.selectedScreenshot = nil
            $0.isShowingFlatGallery = false
            $0.windowTimelineEntries = []
            $0.isLoading = true
        }
        await store.receive(.timelineEntriesLoaded([.screenshot(allScreenshot)])) {
            $0.windowTimelineEntries = [.screenshot(allScreenshot)]
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

        let sessionTimelineLoadCount = LockIsolated(0)
        let windowTimelineLoadCount = LockIsolated(0)
        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.timelineForSession = { _ in
                sessionTimelineLoadCount.withValue { $0 += 1 }
                return []
            }
            $0.persistenceClient.timelineForWindow = { _, _ in
                windowTimelineLoadCount.withValue { $0 += 1 }
                return []
            }
        }

        await store.send(.windowPickerSelectionChanged(.window(id: windowID)))
        XCTAssertEqual(sessionTimelineLoadCount.value, 0)
        XCTAssertEqual(windowTimelineLoadCount.value, 0)

        await store.send(.windowPickerSelectionChanged(.all)) {
            $0.selectedWindowID = nil
            $0.selectedScreenshot = nil
            $0.isShowingFlatGallery = false
            $0.windowTimelineEntries = []
            $0.isLoading = true
        }
        await store.receive(.timelineEntriesLoaded([])) {
            $0.isLoading = false
        }
        XCTAssertEqual(sessionTimelineLoadCount.value, 1)
        XCTAssertEqual(windowTimelineLoadCount.value, 0)

        await store.send(.windowPickerSelectionChanged(.all))
        XCTAssertEqual(sessionTimelineLoadCount.value, 1)
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
