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
            $0.lastWorkspaceEvent = .terminated(app)
            $0.runningApplications[app.bundleIdentifier] = nil
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))
    }

    @MainActor
    func testManualCaptureDoesNotStartFromRunningApplicationDetection() async {
        let app = RunningApplication(
            bundleIdentifier: "com.example.ManualApp",
            displayName: "Manual App",
            processIdentifier: 43
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            captureMode: .manual,
            isEnabled: false
        )

        var initialState = CaptureEngineFeature.State()
        initialState.permissionStatus = .authorized

        let store = TestStore(initialState: initialState) {
            CaptureEngineFeature()
        }

        await store.send(.whitelistUpdated([config])) {
            $0.whitelist = [config.bundleIdentifier: config]
        }
        await store.send(.runningApplicationsLoaded([app])) {
            $0.runningApplications = [app.bundleIdentifier: app]
        }
        await store.send(.workspaceEvent(.launched(app))) {
            $0.lastWorkspaceEvent = .launched(app)
            $0.runningApplications = [app.bundleIdentifier: app]
        }
    }

    @MainActor
    func testManualCaptureStartsAndStopsOnlyFromExplicitActions() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.ManualStartApp",
            displayName: "Manual Start App",
            processIdentifier: 45
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            captureMode: .manual,
            isEnabled: false
        )
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000051"))
        let startedAt = Date(timeIntervalSince1970: 510)
        let endedAt = Date(timeIntervalSince1970: 610)
        let now = LockIsolated(startedAt)
        let clock = TestClock()

        var initialState = CaptureEngineFeature.State()
        initialState.whitelist = [config.bundleIdentifier: config]
        initialState.runningApplications = [app.bundleIdentifier: app]
        initialState.permissionStatus = .authorized

        let store = TestStore(initialState: initialState) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.dateClient.now = { now.value }
            $0.idGeneratorClient.uuid = { sessionID }
            $0.persistenceClient.openSession = { _ in }
            $0.persistenceClient.closeSession = { _, _ in }
            $0.screenCaptureClient.windows = { _ in [] }
        }

        await store.send(.manualCaptureStart(app.bundleIdentifier))

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

        now.setValue(endedAt)
        await store.send(.manualCaptureStop(app.bundleIdentifier)) {
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))
    }

    @MainActor
    func testExplicitPermissionRequestStartsWhitelistedRunningAppsWhenAuthorized() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.PermissionApp",
            displayName: "Permission App",
            processIdentifier: 44
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000050"))
        let startedAt = Date(timeIntervalSince1970: 500)

        var state = CaptureEngineFeature.State()
        state.whitelist = [config.bundleIdentifier: config]
        state.runningApplications = [app.bundleIdentifier: app]
        state.permissionStatus = .denied
        state.lastError = CaptureEngineError.screenRecordingPermissionDenied.localizedDescription

        let clock = TestClock()
        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.capturePermissionClient.request = { .authorized }
            $0.dateClient.now = { startedAt }
            $0.idGeneratorClient.uuid = { sessionID }
            $0.persistenceClient.openSession = { _ in }
            $0.persistenceClient.closeSession = { _, _ in }
            $0.screenCaptureClient.windows = { _ in [] }
        }

        await store.send(.requestPermissionButtonTapped)
        await store.receive(.permissionResolved(.authorized, nil)) {
            $0.permissionStatus = .authorized
            $0.lastError = nil
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
            $0.lastWorkspaceEvent = .terminated(app)
            $0.runningApplications[app.bundleIdentifier] = nil
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))
    }

    @MainActor
    func testWorkspaceEventsUpdateLifecycleDiagnostics() async {
        let app = RunningApplication(
            bundleIdentifier: "com.example.LifecycleApp",
            displayName: "Lifecycle App",
            processIdentifier: 45
        )

        let store = TestStore(initialState: CaptureEngineFeature.State()) {
            CaptureEngineFeature()
        }

        await store.send(.workspaceEvent(.launched(app))) {
            $0.lastWorkspaceEvent = .launched(app)
            $0.runningApplications[app.bundleIdentifier] = app
        }
        await store.send(.workspaceEvent(.activated(app))) {
            $0.lastWorkspaceEvent = .activated(app)
            $0.runningApplications[app.bundleIdentifier] = app
        }
        await store.send(.workspaceEvent(.terminated(app))) {
            $0.lastWorkspaceEvent = .terminated(app)
            $0.runningApplications[app.bundleIdentifier] = nil
        }
    }

    @MainActor
    func testStaleOpenSessionsClosedRecordsDiagnostic() async {
        let store = TestStore(initialState: CaptureEngineFeature.State()) {
            CaptureEngineFeature()
        }

        await store.send(.staleOpenSessionsClosed(2)) {
            $0.lastError = "Closed 2 stale open capture sessions."
            $0.recentDiagnostics = ["Closed 2 stale open capture sessions."]
        }
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
    func testAttachedSheetsAreNotTrackedAsSeparateWindows() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            processIdentifier: 100
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000030")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let parentWindowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000031"))
        let ids = UUIDSequence([parentWindowID])

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
                        systemWindowID: 801,
                        title: "Document",
                        frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                        layer: 0,
                        isOnScreen: true
                    ),
                    CapturableWindow(
                        systemWindowID: 802,
                        title: "Save",
                        frame: CGRect(x: 250, y: 120, width: 500, height: 360),
                        layer: 0,
                        isOnScreen: true
                    ),
                ]
            )
        ) {
            var active = $0.activeSessions[app.bundleIdentifier]!
            active.nextWindowNumber = 2
            active.windowsBySystemID[801] = MonitoredWindow(
                id: parentWindowID,
                sessionID: session.id,
                systemWindowID: 801,
                displayNumber: 1,
                label: "Document",
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

    @MainActor
    func testWhitelistUpdateChangesActiveConfigAndRestartsLoopWhenIntervalChanges() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.IntervalApp",
            displayName: "Interval App",
            processIdentifier: 8
        )
        let originalConfig = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let updatedConfig = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: "Renamed Interval App",
            captureInterval: 5,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000030")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let clock = TestClock()

        var state = CaptureEngineFeature.State()
        state.whitelist = [originalConfig.bundleIdentifier: originalConfig]
        state.permissionStatus = .authorized
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: originalConfig,
            session: session
        )

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.dateClient.now = { Date(timeIntervalSince1970: 20) }
            $0.persistenceClient.closeSession = { _, _ in }
            $0.screenCaptureClient.windows = { _ in [] }
        }

        await store.send(.whitelistUpdated([updatedConfig])) {
            $0.whitelist = [updatedConfig.bundleIdentifier: updatedConfig]
            $0.activeSessions[app.bundleIdentifier]?.config = updatedConfig
        }
        await store.receive(.captureTick(app.bundleIdentifier)) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = true
        }
        await store.receive(.windowsLoaded(app.bundleIdentifier, [])) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = false
        }
        await store.send(.workspaceEvent(.terminated(app))) {
            $0.lastWorkspaceEvent = .terminated(app)
            $0.runningApplications[app.bundleIdentifier] = nil
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))
    }

    @MainActor
    func testWhitelistUpdateDisablesActiveSessionImmediately() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.DisableApp",
            displayName: "Disable App",
            processIdentifier: 9
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let disabledConfig = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: false
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000040")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let endedAt = Date(timeIntervalSince1970: 20)
        let closedSessions = LockIsolated([(UUID, Date)]())

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
            $0.dateClient.now = { endedAt }
            $0.persistenceClient.closeSession = { sessionID, endedAt in
                closedSessions.withValue { $0.append((sessionID, endedAt)) }
            }
        }

        await store.send(.whitelistUpdated([disabledConfig])) {
            $0.whitelist = [disabledConfig.bundleIdentifier: disabledConfig]
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))
        XCTAssertEqual(closedSessions.value.count, 1)
        XCTAssertEqual(closedSessions.value.first?.0, session.id)
        XCTAssertEqual(closedSessions.value.first?.1, endedAt)
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
