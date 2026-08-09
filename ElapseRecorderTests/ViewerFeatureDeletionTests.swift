import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class ViewerFeatureDeletionTests: XCTestCase {
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
            $0.maintenanceServiceClient.deleteSessions = { ids, _ in
                deletedFileSessions.setValue([(session.bundleIdentifier, session.id)])
                deletedMetadataSessions.setValue(ids)
                return ids.count
            }
            $0.persistenceClient.apps = { [] }
            $0.persistenceClient.sessions = { _ in [] }
            $0.persistenceClient.windows = { _ in [] }
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
            $0.maintenanceServiceClient.deleteSessions = { ids, _ in
                deletedFileSessions.setValue([(deletedSession.bundleIdentifier, deletedSession.id)])
                deletedMetadataSessions.setValue(ids)
                return ids.count
            }
            $0.persistenceClient.apps = { [] }
            $0.persistenceClient.sessions = { _ in [] }
            $0.persistenceClient.windows = { _ in [] }
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
