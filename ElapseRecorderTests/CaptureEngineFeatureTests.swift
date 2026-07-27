import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
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

        let expectedSession = CaptureSession(
            id: sessionID,
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: startedAt
        )

        await store.send(.runningApplicationsLoaded([app])) {
            $0.runningApplications = [app.bundleIdentifier: app]
            $0.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
                application: app,
                config: config,
                session: expectedSession
            )
        }

        await store.receive(.sessionOpened(expectedSession, app))
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
    func testDuplicateStartRequestsAreIgnoredWhileSessionOpenIsPending() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.RacyAutoApp",
            displayName: "Racy Auto App",
            processIdentifier: 142
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000054"))
        let startedAt = Date(timeIntervalSince1970: 540)
        let clock = TestClock()
        let openedSessions = LockIsolated([CaptureSession]())

        var initialState = CaptureEngineFeature.State()
        initialState.whitelist = [config.bundleIdentifier: config]
        initialState.permissionStatus = .authorized

        let store = TestStore(initialState: initialState) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.capturePermissionClient.status = { .authorized }
            $0.capturePermissionClient.request = { .authorized }
            $0.continuousClock = clock
            $0.dateClient.now = { startedAt }
            $0.idGeneratorClient.uuid = { sessionID }
            $0.persistenceClient.closeSession = { _, _ in }
            $0.persistenceClient.openSession = { session in
                try await clock.sleep(for: .seconds(1))
                openedSessions.withValue { $0.append(session) }
            }
            $0.screenCaptureClient.windows = { _ in [] }
        }

        let expectedSession = CaptureSession(
            id: sessionID,
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: startedAt
        )

        await store.send(.runningApplicationsLoaded([app])) {
            $0.runningApplications = [app.bundleIdentifier: app]
            $0.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
                application: app,
                config: config,
                session: expectedSession
            )
        }
        await Task.yield()
        await store.send(.whitelistUpdated([config]))
        XCTAssertEqual(openedSessions.value.map(\.id), [])
        await clock.advance(by: .seconds(1))

        await store.receive(.sessionOpened(expectedSession, app))
        await store.receive(.captureTick(app.bundleIdentifier)) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = true
        }
        await store.receive(.windowsLoaded(app.bundleIdentifier, [])) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = false
        }

        XCTAssertEqual(openedSessions.value.map(\.id), [sessionID])
        await store.send(.workspaceEvent(.terminated(app))) {
            $0.lastWorkspaceEvent = .terminated(app)
            $0.runningApplications[app.bundleIdentifier] = nil
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))
    }

    @MainActor
    func testLaunchStormOpensExactlyOneSession() async throws {
        // Reproduces the real launch sequence the user hit: running-app load, launch and
        // activate workspace events, and both forms of permission resolution all arrive in
        // a burst. The synchronous start chokepoint must collapse them into one session.
        let app = RunningApplication(
            bundleIdentifier: "com.example.LaunchStormApp",
            displayName: "Launch Storm App",
            processIdentifier: 200
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000200"))
        let clock = TestClock()
        let openedSessions = LockIsolated([CaptureSession]())

        var initialState = CaptureEngineFeature.State()
        initialState.whitelist = [config.bundleIdentifier: config]
        initialState.permissionStatus = .authorized

        let store = TestStore(initialState: initialState) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.capturePermissionClient.status = { .authorized }
            $0.capturePermissionClient.request = { .authorized }
            $0.dateClient.now = { Date(timeIntervalSince1970: 1000) }
            $0.idGeneratorClient.uuid = { sessionID }
            $0.persistenceClient.openSession = { session in
                openedSessions.withValue { $0.append(session) }
            }
            $0.persistenceClient.closeSession = { _, _ in }
            $0.screenCaptureClient.windows = { _ in [] }
            $0.loggingClient.log = { _, _, _ in }
        }
        store.exhaustivity = .off

        await store.send(.runningApplicationsLoaded([app]))
        await store.send(.workspaceEvent(.launched(app)))
        await store.send(.workspaceEvent(.activated(app)))
        await store.send(.permissionResolved(.authorized, nil))
        await store.send(.permissionResolved(.authorized, app))

        XCTAssertEqual(store.state.activeSessions[app.bundleIdentifier]?.session.id, sessionID)

        await store.send(.workspaceEvent(.terminated(app)))

        XCTAssertNil(store.state.activeSessions[app.bundleIdentifier])
        XCTAssertEqual(openedSessions.value.map(\.id), [sessionID])
    }

    @MainActor
    func testRunningApplicationRegisteredMergesWithoutClearingOtherApps() async {
        let existing = RunningApplication(
            bundleIdentifier: "com.example.ExistingApp",
            displayName: "Existing App",
            processIdentifier: 210
        )
        let registered = RunningApplication(
            bundleIdentifier: "com.example.RegisteredApp",
            displayName: "Registered App",
            processIdentifier: 211
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: registered.bundleIdentifier,
            displayName: registered.displayName,
            captureInterval: 60,
            captureMode: .manual,
            isEnabled: false
        )

        var initialState = CaptureEngineFeature.State()
        initialState.permissionStatus = .authorized
        initialState.whitelist = [config.bundleIdentifier: config]
        initialState.runningApplications = [existing.bundleIdentifier: existing]

        let store = TestStore(initialState: initialState) {
            CaptureEngineFeature()
        }

        // Manual config: registering must merge the app in without dropping the existing
        // one, and must not auto-start a session (manual apps wait for an explicit start).
        await store.send(.runningApplicationRegistered(registered)) {
            $0.runningApplications[registered.bundleIdentifier] = registered
        }
    }

    @MainActor
    func testDuplicateSessionOpenedIsClosedInsteadOfReplacingActiveSession() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.DuplicateOpenedApp",
            displayName: "Duplicate Opened App",
            processIdentifier: 143
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let activeSession = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000055")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 550)
        )
        let duplicateSession = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000056")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 551)
        )
        let closedSessions = LockIsolated([(UUID, Date)]())
        let closedAt = Date(timeIntervalSince1970: 552)

        var state = CaptureEngineFeature.State()
        state.whitelist = [config.bundleIdentifier: config]
        state.runningApplications = [app.bundleIdentifier: app]
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: config,
            session: activeSession
        )

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.dateClient.now = { closedAt }
            $0.persistenceClient.closeSession = { sessionID, endedAt in
                closedSessions.withValue { $0.append((sessionID, endedAt)) }
            }
        }

        await store.send(.sessionOpened(duplicateSession, app))
        await store.receive(.sessionClosed(app.bundleIdentifier))

        XCTAssertEqual(store.state.activeSessions[app.bundleIdentifier]?.session, activeSession)
        XCTAssertEqual(closedSessions.value.map(\.0), [duplicateSession.id])
        XCTAssertEqual(closedSessions.value.map(\.1), [closedAt])
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
    func testUserCaptureStartsAndStopsOnlyFromExplicitActions() async throws {
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

        let expectedSession = CaptureSession(
            id: sessionID,
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: startedAt
        )

        await store.send(.captureStart(app.bundleIdentifier)) {
            $0.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
                application: app,
                config: config,
                session: expectedSession
            )
        }

        await store.receive(.sessionOpened(expectedSession, app))
        await store.receive(.captureTick(app.bundleIdentifier)) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = true
        }
        await store.receive(.windowsLoaded(app.bundleIdentifier, [])) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = false
        }

        now.setValue(endedAt)
        await store.send(.captureStop(app.bundleIdentifier)) {
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))
    }

    @MainActor
    func testSwitchingAutoSessionToManualKeepsSessionUntilUserStops() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.ModeSwitchApp",
            displayName: "Mode Switch App",
            processIdentifier: 46
        )
        let autoConfig = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            captureMode: .auto,
            isEnabled: true
        )
        let manualConfig = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            captureMode: .manual,
            isEnabled: false
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000052")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 520)
        )
        let endedAt = Date(timeIntervalSince1970: 620)
        let closedSessions = LockIsolated([(UUID, Date)]())

        var state = CaptureEngineFeature.State()
        state.whitelist = [app.bundleIdentifier: autoConfig]
        state.runningApplications = [app.bundleIdentifier: app]
        state.permissionStatus = .authorized
        state.activeSessions = [
            app.bundleIdentifier: CaptureEngineFeature.State.ActiveSession(
                application: app,
                config: autoConfig,
                session: session
            ),
        ]

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.dateClient.now = { endedAt }
            $0.persistenceClient.closeSession = { sessionID, endedAt in
                closedSessions.withValue { $0.append((sessionID, endedAt)) }
            }
        }

        await store.send(.whitelistUpdated([manualConfig])) {
            $0.whitelist = [app.bundleIdentifier: manualConfig]
            $0.activeSessions[app.bundleIdentifier]?.config = manualConfig
        }

        await store.send(.captureStop(app.bundleIdentifier)) {
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))

        XCTAssertEqual(closedSessions.value.map(\.0), [session.id])
        XCTAssertEqual(closedSessions.value.map(\.1), [endedAt])
    }

    @MainActor
    func testSwitchingManualSessionToAutoKeepsSessionUntilAppTerminates() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.ManualToAutoApp",
            displayName: "Manual To Auto App",
            processIdentifier: 47
        )
        let manualConfig = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            captureMode: .manual,
            isEnabled: false
        )
        let autoConfig = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            captureMode: .auto,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000053")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 530)
        )
        let endedAt = Date(timeIntervalSince1970: 630)
        let closedSessions = LockIsolated([(UUID, Date)]())

        var state = CaptureEngineFeature.State()
        state.whitelist = [app.bundleIdentifier: manualConfig]
        state.runningApplications = [app.bundleIdentifier: app]
        state.permissionStatus = .authorized
        state.activeSessions = [
            app.bundleIdentifier: CaptureEngineFeature.State.ActiveSession(
                application: app,
                config: manualConfig,
                session: session
            ),
        ]

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.dateClient.now = { endedAt }
            $0.persistenceClient.closeSession = { sessionID, endedAt in
                closedSessions.withValue { $0.append((sessionID, endedAt)) }
            }
        }

        await store.send(.whitelistUpdated([autoConfig])) {
            $0.whitelist = [app.bundleIdentifier: autoConfig]
            $0.activeSessions[app.bundleIdentifier]?.config = autoConfig
        }

        await store.send(.workspaceEvent(.terminated(app))) {
            $0.lastWorkspaceEvent = .terminated(app)
            $0.runningApplications[app.bundleIdentifier] = nil
            $0.activeSessions[app.bundleIdentifier] = nil
        }
        await store.receive(.sessionClosed(app.bundleIdentifier))

        XCTAssertEqual(closedSessions.value.map(\.0), [session.id])
        XCTAssertEqual(closedSessions.value.map(\.1), [endedAt])
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

        let expectedSession = CaptureSession(
            id: sessionID,
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: startedAt
        )

        await store.send(.requestPermissionButtonTapped)
        await store.receive(.permissionResolved(.authorized, nil)) {
            $0.permissionStatus = .authorized
            $0.lastError = nil
            $0.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
                application: app,
                config: config,
                session: expectedSession
            )
        }

        await store.receive(.sessionOpened(expectedSession, app))
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
            $0.lastError = CaptureDiagnostic.closedStaleSessions(count: 2).message
            $0.recentDiagnostics = [.closedStaleSessions(count: 2)]
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
        let firstObservationID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        let secondWindowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000013"))
        let secondObservationID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000014"))
        let ids = UUIDSequence([firstWindowID, firstObservationID, secondWindowID, secondObservationID])

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
            $0.persistenceClient.recordCaptureUnavailable = { _ in }
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
                lastSeenAt: Date(timeIntervalSince1970: 10),
                titleHistory: [
                    WindowTitleObservation(
                        id: firstObservationID,
                        title: "Canvas",
                        observedAt: Date(timeIntervalSince1970: 10)
                    ),
                ]
            )
            active.windowsBySystemID[777] = MonitoredWindow(
                id: secondWindowID,
                sessionID: session.id,
                systemWindowID: 777,
                displayNumber: 2,
                label: "Reference",
                firstSeenAt: Date(timeIntervalSince1970: 10),
                lastSeenAt: Date(timeIntervalSince1970: 10),
                titleHistory: [
                    WindowTitleObservation(
                        id: secondObservationID,
                        title: "Reference",
                        observedAt: Date(timeIntervalSince1970: 10)
                    ),
                ]
            )
            $0.activeSessions[app.bundleIdentifier] = active
        }
    }

    @MainActor
    func testWindowTitleChangeRecordsNewObservationInHistory() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.TextApp",
            displayName: "Text App",
            processIdentifier: 55
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"))
        let firstObservationID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"))
        let secondObservationID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A3"))
        let ids = UUIDSequence([windowID, firstObservationID, secondObservationID])

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
            $0.persistenceClient.recordCaptureUnavailable = { _ in }
            $0.persistenceClient.upsertWindow = { _ in }
            $0.screenCaptureClient.capture = { _ in throw CaptureEngineError.windowCaptureFailed(systemWindowID: -1) }
            $0.loggingClient.log = { _, _, _ in }
        }
        store.exhaustivity = .off

        // First tick: the window is seen as "Untitled".
        await store.send(
            .windowsLoaded(app.bundleIdentifier, [
                CapturableWindow(
                    systemWindowID: 700,
                    title: "Untitled",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    layer: 0,
                    isOnScreen: true
                ),
            ])
        )
        await store.skipReceivedActions()

        // Second tick: the same window (same system id) is now "Notes.txt".
        await store.send(
            .windowsLoaded(app.bundleIdentifier, [
                CapturableWindow(
                    systemWindowID: 700,
                    title: "Notes.txt",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    layer: 0,
                    isOnScreen: true
                ),
            ])
        )
        await store.skipReceivedActions()

        let history = try XCTUnwrap(
            store.state.activeSessions[app.bundleIdentifier]?.windowsBySystemID[700]?.titleHistory
        )
        XCTAssertEqual(history.map(\.title), ["Untitled", "Notes.txt"])
        XCTAssertEqual(history.map(\.id), [firstObservationID, secondObservationID])
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
        let observationID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000032"))
        let ids = UUIDSequence([parentWindowID, observationID])

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
            $0.persistenceClient.recordCaptureUnavailable = { _ in }
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
                lastSeenAt: Date(timeIntervalSince1970: 10),
                titleHistory: [
                    WindowTitleObservation(
                        id: observationID,
                        title: "Document",
                        observedAt: Date(timeIntervalSince1970: 10)
                    ),
                ]
            )
            $0.activeSessions[app.bundleIdentifier] = active
        }
    }

    @MainActor
    func testUnknownUnavailableWindowsDoNotRecordPlaceholderBeforeFirstRealCapture() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.HiddenApp",
            displayName: "Hidden App",
            processIdentifier: 101
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000060")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let seenAt = Date(timeIntervalSince1970: 60)
        let recordedPlaceholders = LockIsolated([CaptureUnavailableRecord]())

        var state = CaptureEngineFeature.State()
        state.whitelist = [config.bundleIdentifier: config]
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: config,
            session: session,
            isCaptureInFlight: true
        )

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.dateClient.now = { seenAt }
            $0.persistenceClient.recordCaptureUnavailable = { record in
                recordedPlaceholders.withValue { $0.append(record) }
            }
        }

        await store.send(.windowsLoaded(app.bundleIdentifier, [])) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = false
        }

        XCTAssertEqual(recordedPlaceholders.value, [])
    }

    @MainActor
    func testPreviouslySeenWindowsDisappearingRecordUnavailablePlaceholder() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.NormalMinimizeApp",
            displayName: "Normal Minimize App",
            processIdentifier: 103
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000080")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let window = try MonitoredWindow(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000081")),
            sessionID: session.id,
            systemWindowID: 921,
            displayNumber: 1,
            label: "Main",
            firstSeenAt: Date(timeIntervalSince1970: 10),
            lastSeenAt: Date(timeIntervalSince1970: 10)
        )
        let unavailableID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000082"))
        let seenAt = Date(timeIntervalSince1970: 80)
        let recordedPlaceholders = LockIsolated([CaptureUnavailableRecord]())

        var state = CaptureEngineFeature.State()
        state.whitelist = [config.bundleIdentifier: config]
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: config,
            session: session,
            windowsBySystemID: [window.systemWindowID: window],
            isCaptureInFlight: true
        )

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.dateClient.now = { seenAt }
            $0.idGeneratorClient.uuid = { unavailableID }
            $0.persistenceClient.recordCaptureUnavailable = { record in
                recordedPlaceholders.withValue { $0.append(record) }
            }
        }

        let expectedRecord = CaptureUnavailableRecord(
            id: unavailableID,
            sessionID: session.id,
            startedAt: seenAt,
            endedAt: seenAt,
            reason: .windowMinimized
        )

        await store.send(.windowsLoaded(app.bundleIdentifier, [])) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = false
            $0.activeSessions[app.bundleIdentifier]?.captureUnavailableReason = .windowMinimized
            $0.activeSessions[app.bundleIdentifier]?.unavailableRecordID = unavailableID
            $0.activeSessions[app.bundleIdentifier]?.unavailableStartedAt = seenAt
        }
        await store.receive(.captureUnavailableRecorded(expectedRecord))

        XCTAssertEqual(recordedPlaceholders.value, [expectedRecord])
    }

    @MainActor
    func testStageManagerStowedWindowIsTreatedAsUnavailable() async throws {
        // A window stowed by Stage Manager stays on-screen (isOnScreen == true) but the
        // live layer flags it isStageManagerStowed because its presented size no longer
        // matches the app's real Accessibility size. It must be skipped, not captured, and
        // recorded as a placeholder because the session has already seen real windows.
        let app = RunningApplication(
            bundleIdentifier: "com.example.StowedApp",
            displayName: "Stowed App",
            processIdentifier: 105
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let window = try MonitoredWindow(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")),
            sessionID: session.id,
            systemWindowID: 941,
            displayNumber: 1,
            label: "Main",
            firstSeenAt: Date(timeIntervalSince1970: 10),
            lastSeenAt: Date(timeIntervalSince1970: 10)
        )
        let unavailableID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"))
        let seenAt = Date(timeIntervalSince1970: 95)
        let recordedPlaceholders = LockIsolated([CaptureUnavailableRecord]())
        let capturedWindowIDs = LockIsolated([Int]())

        var state = CaptureEngineFeature.State()
        state.whitelist = [config.bundleIdentifier: config]
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: config,
            session: session,
            windowsBySystemID: [window.systemWindowID: window],
            isCaptureInFlight: true
        )

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.dateClient.now = { seenAt }
            $0.idGeneratorClient.uuid = { unavailableID }
            $0.persistenceClient.recordCaptureUnavailable = { record in
                recordedPlaceholders.withValue { $0.append(record) }
            }
            $0.screenCaptureClient.capture = { windowID in
                capturedWindowIDs.withValue { $0.append(windowID) }
                throw CaptureEngineError.windowCaptureFailed(systemWindowID: windowID)
            }
        }

        let expectedRecord = CaptureUnavailableRecord(
            id: unavailableID,
            sessionID: session.id,
            startedAt: seenAt,
            endedAt: seenAt,
            reason: .windowMinimized
        )

        await store.send(
            .windowsLoaded(
                app.bundleIdentifier,
                [
                    CapturableWindow(
                        systemWindowID: window.systemWindowID,
                        title: window.label,
                        frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                        layer: 0,
                        isOnScreen: true,
                        isStageManagerStowed: true
                    ),
                ]
            )
        ) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = false
            $0.activeSessions[app.bundleIdentifier]?.captureUnavailableReason = .windowMinimized
            $0.activeSessions[app.bundleIdentifier]?.unavailableRecordID = unavailableID
            $0.activeSessions[app.bundleIdentifier]?.unavailableStartedAt = seenAt
        }
        await store.receive(.captureUnavailableRecorded(expectedRecord))

        XCTAssertEqual(recordedPlaceholders.value, [expectedRecord])
        XCTAssertEqual(capturedWindowIDs.value, [])
    }

    @MainActor
    func testUnavailablePlaceholderExtendsAcrossUnavailableSpan() async throws {
        let app = RunningApplication(
            bundleIdentifier: "com.example.StageManagedApp",
            displayName: "Stage Managed App",
            processIdentifier: 104
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000090")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let window = try MonitoredWindow(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000091")),
            sessionID: session.id,
            systemWindowID: 931,
            displayNumber: 1,
            label: "Main",
            firstSeenAt: Date(timeIntervalSince1970: 10),
            lastSeenAt: Date(timeIntervalSince1970: 10)
        )
        let unavailableID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000092"))
        let firstSeenAt = Date(timeIntervalSince1970: 90)
        let secondSeenAt = Date(timeIntervalSince1970: 150)
        let now = LockIsolated(firstSeenAt)
        let recordedPlaceholders = LockIsolated([CaptureUnavailableRecord]())

        var state = CaptureEngineFeature.State()
        state.whitelist = [config.bundleIdentifier: config]
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: config,
            session: session,
            windowsBySystemID: [window.systemWindowID: window],
            isCaptureInFlight: true
        )

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.dateClient.now = { now.value }
            $0.idGeneratorClient.uuid = { unavailableID }
            $0.persistenceClient.recordCaptureUnavailable = { record in
                recordedPlaceholders.withValue { $0.append(record) }
            }
        }

        let openingRecord = CaptureUnavailableRecord(
            id: unavailableID,
            sessionID: session.id,
            startedAt: firstSeenAt,
            endedAt: firstSeenAt,
            reason: .windowMinimized
        )

        // First tick opens the span (started == ended == first tick).
        await store.send(.windowsLoaded(app.bundleIdentifier, [])) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = false
            $0.activeSessions[app.bundleIdentifier]?.captureUnavailableReason = .windowMinimized
            $0.activeSessions[app.bundleIdentifier]?.unavailableRecordID = unavailableID
            $0.activeSessions[app.bundleIdentifier]?.unavailableStartedAt = firstSeenAt
        }
        await store.receive(.captureUnavailableRecorded(openingRecord))

        // A later tick still unavailable extends the same record's end time (same id,
        // same start, new end) rather than opening a second placeholder.
        now.setValue(secondSeenAt)
        let extendedRecord = CaptureUnavailableRecord(
            id: unavailableID,
            sessionID: session.id,
            startedAt: firstSeenAt,
            endedAt: secondSeenAt,
            reason: .windowMinimized
        )
        await store.send(.windowsLoaded(app.bundleIdentifier, []))
        await store.receive(.captureUnavailableRecorded(extendedRecord))

        XCTAssertEqual(recordedPlaceholders.value, [openingRecord, extendedRecord])
        XCTAssertEqual(Set(recordedPlaceholders.value.map(\.id)), [unavailableID])
    }

    @MainActor
    func testCaptureFailureIsDiagnosticOnlyAndKeepsSessionRunning() async throws {
        // With Stage Manager / minimized windows filtered out before capture, a capture
        // throwing now means a transient error, not unavailability. It is recorded as a
        // diagnostic and the cycle finishes without a timeline placeholder (the placeholder
        // path belongs solely to windowsLoaded when no window is capturable).
        let app = RunningApplication(
            bundleIdentifier: "com.example.TransientFailureApp",
            displayName: "Transient Failure App",
            processIdentifier: 102
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let session = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000070")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let window = try MonitoredWindow(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000071")),
            sessionID: session.id,
            systemWindowID: 911,
            displayNumber: 1,
            label: "Main",
            firstSeenAt: Date(timeIntervalSince1970: 10),
            lastSeenAt: Date(timeIntervalSince1970: 10),
            titleHistory: [
                WindowTitleObservation(
                    id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000073")),
                    title: "Main",
                    observedAt: Date(timeIntervalSince1970: 10)
                ),
            ]
        )
        let failedAt = Date(timeIntervalSince1970: 70)
        let error = CaptureEngineError.windowCaptureFailed(systemWindowID: window.systemWindowID)
        let recordedPlaceholders = LockIsolated([CaptureUnavailableRecord]())

        var state = CaptureEngineFeature.State()
        state.whitelist = [config.bundleIdentifier: config]
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: config,
            session: session,
            windowsBySystemID: [window.systemWindowID: window],
            isCaptureInFlight: true
        )

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.capturePreferencesClient.encodingOptions = { .defaultValue }
            $0.capturePreferencesClient.thumbnailMaximumPixelSize = { 320 }
            $0.dateClient.now = { failedAt }
            $0.fileStorageClient.screenshotURL = { _, _, _, _ in URL(filePath: "/tmp/unused.heic") }
            $0.fileStorageClient.write = { data, _ in data.count }
            $0.imageEncodingClient.encode = { _, _ in Data() }
            $0.idGeneratorClient.uuid = { UUID(uuidString: "00000000-0000-0000-0000-000000000072")! }
            $0.persistenceClient.recordCaptureUnavailable = { record in
                recordedPlaceholders.withValue { $0.append(record) }
            }
            $0.persistenceClient.upsertWindow = { _ in }
            $0.screenCaptureClient.capture = { _ in throw error }
            $0.loggingClient.log = { _, _, _ in }
        }

        await store.send(
            .windowsLoaded(
                app.bundleIdentifier,
                [
                    CapturableWindow(
                        systemWindowID: window.systemWindowID,
                        title: window.label,
                        frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                        layer: 0,
                        isOnScreen: true
                    ),
                ]
            )
        ) {
            $0.activeSessions[app.bundleIdentifier]?.windowsBySystemID[window.systemWindowID]?.lastSeenAt = failedAt
        }
        await store.receive(.screenshotFailed(app.bundleIdentifier, error.localizedDescription)) {
            $0.lastError = error.localizedDescription
            $0.recentDiagnostics = [.failure(error.localizedDescription)]
        }
        await store.receive(.captureCycleFinished(app.bundleIdentifier)) {
            $0.activeSessions[app.bundleIdentifier]?.isCaptureInFlight = false
        }

        XCTAssertEqual(recordedPlaceholders.value, [])
        XCTAssertNotNil(store.state.activeSessions[app.bundleIdentifier])
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

    // MARK: - Frame persistence

    @MainActor
    func testIdenticalConsecutiveFramesAreRecordedAtEachCaptureCycle() async {
        let recorded = LockIsolated<[ScreenshotRecord]>([])
        let hashes = LockIsolated<[UInt64]>([0b0111, 0b0111])
        let store = makeCaptureStore(recorded: recorded, hashes: hashes)

        await store.send(.windowsLoaded("com.example.Dedup", [Self.captureWindow]))
        await store.skipReceivedActions()
        await store.send(.windowsLoaded("com.example.Dedup", [Self.captureWindow]))
        await store.skipReceivedActions()

        XCTAssertEqual(recorded.value.count, 2, "each successful capture cycle should persist a frame")
    }

    @MainActor
    func testRecordedScreenshotCarriesDimensionsAndHash() async {
        let recorded = LockIsolated<[ScreenshotRecord]>([])
        let hashes = LockIsolated<[UInt64]>([0x00AB_CDEF_1234_5678])
        let store = makeCaptureStore(recorded: recorded, hashes: hashes)

        await store.send(.windowsLoaded("com.example.Dedup", [Self.captureWindow]))
        await store.skipReceivedActions()

        let record = recorded.value.first
        XCTAssertEqual(record?.perceptualHash, 0x00AB_CDEF_1234_5678)
        XCTAssertEqual(record?.pixelWidth, 6)
        XCTAssertEqual(record?.pixelHeight, 4)
    }

    private static let captureWindow = CapturableWindow(
        systemWindowID: 501,
        title: "Canvas",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        layer: 0,
        isOnScreen: true
    )

    /// Builds a TestStore wired for frame-persistence tests: one active session, controlled
    /// hash values, and side-effect capture of every recorded frame.
    @MainActor
    private func makeCaptureStore(
        recorded: LockIsolated<[ScreenshotRecord]>,
        hashes: LockIsolated<[UInt64]>,
        now: LockIsolated<Date> = LockIsolated(Date(timeIntervalSince1970: 10))
    ) -> TestStore<CaptureEngineFeature.State, CaptureEngineFeature.Action> {
        let app = RunningApplication(
            bundleIdentifier: "com.example.Dedup",
            displayName: "Dedup",
            processIdentifier: 77
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 60,
            isEnabled: true
        )
        let session = CaptureSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: app.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 1)
        )

        var state = CaptureEngineFeature.State()
        state.whitelist = [config.bundleIdentifier: config]
        state.activeSessions[app.bundleIdentifier] = CaptureEngineFeature.State.ActiveSession(
            application: app,
            config: config,
            session: session
        )

        let counter = LockIsolated(0)

        let store = TestStore(initialState: state) {
            CaptureEngineFeature()
        } withDependencies: {
            $0.dateClient.now = { now.value }
            $0.idGeneratorClient.uuid = {
                counter.withValue { value in
                    value += 1
                    return UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", value))")!
                }
            }
            $0.capturePreferencesClient.encodingOptions = { .defaultValue }
            $0.capturePreferencesClient.thumbnailMaximumPixelSize = { 320 }
            $0.perceptualHashClient.hash = { _ in
                hashes.withValue { $0.isEmpty ? 0 : $0.removeFirst() }
            }
            $0.screenCaptureClient.capture = { _ in Self.makeSolidImage(width: 6, height: 4) }
            $0.imageEncodingClient.encode = { _, _ in Data([0x1]) }
            $0.fileStorageClient.screenshotURL = { _, _, _, _ in URL(filePath: "/tmp/frame.heic") }
            $0.fileStorageClient.write = { data, _ in data.count }
            $0.persistenceClient.upsertWindow = { _ in }
            $0.persistenceClient.recordScreenshot = { record in
                recorded.withValue { $0.append(record) }
            }
            $0.loggingClient.log = { _, _, _ in }
        }
        store.exhaustivity = .off
        return store
    }

    private static func makeSolidImage(width: Int, height: Int) -> CapturedImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CapturedImage(cgImage: context.makeImage()!)
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
