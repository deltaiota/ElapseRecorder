import ComposableArchitecture
import CoreGraphics
@testable import ElapsedRecord
import Foundation
import XCTest

final class CaptureEngineFeatureTests: XCTestCase {
    @MainActor
    func testRunningWhitelistedAppStartsAndStopsSession() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.DrawingApp",
            displayName: "Drawing App",
            processIdentifier: 42
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let startedAt = Date(timeIntervalSince1970: 100)
        let clock = TestClock()

        var initialState = CaptureEngineFeature.State()
        initialState.permissionStatus = .authorized

        let store = TestStore(initialState: initialState) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.capturePermissionClient.status = { .authorized }
            $0.capturePermissionClient.request = { .authorized }
            $0.dateClient.now = { startedAt }
            $0.idGeneratorClient.uuid = { sessionID }
            $0.persistenceClient.openSession = { _ in }
            $0.persistenceClient.closeSession = { _, _ in }
            $0.screenCaptureClient.windows = { _ in [] }
            $0.loggingClient.log = { _, _, _ in }
            $0.workspaceClient.runningApplications = { [app] }
            $0.workspaceClient.events = {
                AsyncStream { continuation in
                    continuation.finish()
                }
            }
        }

        await store.send(.whitelistUpdated([config])) {
            $0.whitelist = [config.bundleIdentifier: config]
        }
        await store.send(.runningApplicationsLoaded([app])) {
            $0.runningApplications = [app.bundleIdentifier: app]
        }

        let expectedSession = CaptureSession(
            id: sessionID,
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: startedAt
        )

        await store.receive(.sessionOpened(expectedSession, app)) {
            $0.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
                application: app,
                config: config,
                session: expectedSession
            )
        }
        await store.receive(.captureTick(app.bundleIdentifier)) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = true
        }
        await store.receive(.windowsLoaded(app.bundleIdentifier, [])) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = false
        }

        await store.send(.workspaceEvent(.terminated(app))) {
            $0.runningApplications[app.bundleIdentifier] = nil
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))
    }

    @MainActor
    func testWindowsReceiveStableSessionScopedNumbers() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.Modeler",
            displayName: "Modeler",
            processIdentifier: 99
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000010")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let firstWindowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        let secondWindowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        let ids = UUIDSequence([firstWindowID, secondWindowID])

        var state = CaptureEngineFeature.State()
        state.whitelist = [config.bundleIdentifier: config]
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: config,
            session: session
        )

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.dateClient.now = { Date(timeIntervalSince1970: 10) }
            $0.capturePreferencesClient.encodingOptions = { .defaultValue }
            $0.capturePreferencesClient.thumbnailMaximumPixelSize = { 320 }
            $0.fileStorageClient.screenshotURL = { _, _, _, _ in URL(filePath: "/tmp/unused.heic") }
            $0.fileStorageClient.write = { data, _ in data.count }
            $0.imageEncodingClient.encode = { _, _ in Data() }
            $0.idGeneratorClient.uuid = { ids.next() }
            $0.persistenceClient.upsertWindow = { _ in }
            $0.screenCaptureClient.capture = { _ in throw CaptureEngineError.windowCaptureFailed(systemWindowID: -1) }
            $0.loggingClient.log = { _, _, _ in }
        }
        store.exhaustivity = .off

        await store.send(
            .windowsLoaded(
                app.bundleIdentifier,
                [
                    CapturableWindow(
                        systemWindowID: 501,
                        title: "Canvas",
                        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                        layer: 0,
                        isOnScreen: true
                    ),
                    CapturableWindow(
                        systemWindowID: 777,
                        title: "Reference",
                        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                        layer: 0,
                        isOnScreen: true
                    ),
                ]
            )
        ) {
            var active = $0.activeSessions[app.bundleIdentifier]!
            active.nextWindowNumber = 3
            active.windowsBySystemID[501] = MonitoredWindow(
                id: firstWindowID,
                sessionID: session.id,
                systemWindowID: 501,
                displayNumber: 1,
                label: "Canvas",
                firstSeenAt: Date(timeIntervalSince1970: 10),
                lastSeenAt: Date(timeIntervalSince1970: 10)
            )
            active.windowsBySystemID[777] = MonitoredWindow(
                id: secondWindowID,
                sessionID: session.id,
                systemWindowID: 777,
                displayNumber: 2,
                label: "Reference",
                firstSeenAt: Date(timeIntervalSince1970: 10),
                lastSeenAt: Date(timeIntervalSince1970: 10)
            )
            $0.activeSessions[app.bundleIdentifier] = active
        }
    }

    @MainActor
    func testCaptureTickIsIgnoredWhileCycleIsInFlight() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.SlowApp",
            displayName: "Slow App",
            processIdentifier: 7
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 1,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000020")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )

        var state = CaptureEngineFeature.State()
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: config,
            session: session,
            isCaptureInFlight: true
        )

        let windowEnumerationCount = LockIsolated(0)
        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.screenCaptureClient.windows = { _ in
                windowEnumerationCount.withValue { $0 += 1 }
                return []
            }
        }

        await store.send(.captureTick(app.bundleIdentifier))
        XCTAssertEqual(windowEnumerationCount.value, 0)
    }

    private final class UUIDSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID]

        init(_ values: [UUID]) {
            self.values = values.reversed()
        }

        func next() -> UUID {
            lock.lock()
            defer { lock.unlock() }
            return values.removeLast()
        }
    }
}
