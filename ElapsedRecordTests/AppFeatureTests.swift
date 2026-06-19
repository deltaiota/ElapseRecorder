import ComposableArchitecture
@testable import ElapsedRecord
import Foundation
import XCTest

final class AppFeatureTests: XCTestCase {
    @MainActor
    func testLoadedWhitelistUpdatesWhitelistStateAndCaptureEngine() async {
        let config = WhitelistedAppConfig(
            bundleIdentifier: "com.example.PersistentApp",
            displayName: "Persistent App",
            captureInterval: 12,
            isEnabled: true
        )

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        await store.send(.savedWhitelistLoaded([config])) {
            $0.whitelistConfigs = [config]
            $0.draftBundleIdentifier = config.bundleIdentifier
            $0.draftDisplayName = config.displayName
            $0.draftIntervalSeconds = config.captureInterval
        }
        await store.receive(.captureEngine(.whitelistUpdated([config]))) {
            $0.captureEngine.whitelist = [config.bundleIdentifier: config]
        }
    }

    @MainActor
    func testAddingAndRemovingDraftWhitelistPersistsChanges() async {
        let savedConfigs = LockIsolated([[WhitelistedAppConfig]]())
        var state = AppFeature.State()
        state.draftBundleIdentifier = "com.example.CaptureMe"
        state.draftDisplayName = "Capture Me"
        state.draftIntervalSeconds = 3

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.whitelistConfigurationClient.save = { configs in
                savedConfigs.withValue { $0.append(configs) }
            }
        }

        let expectedConfig = WhitelistedAppConfig(
            bundleIdentifier: "com.example.CaptureMe",
            displayName: "Capture Me",
            captureInterval: 3,
            isEnabled: true
        )

        await store.send(.addDraftWhitelistButtonTapped) {
            $0.whitelistConfigs = [expectedConfig]
        }
        await store.receive(.captureEngine(.whitelistUpdated([expectedConfig]))) {
            $0.captureEngine.whitelist = [expectedConfig.bundleIdentifier: expectedConfig]
        }

        await store.send(.removeWhitelistButtonTapped(expectedConfig.bundleIdentifier)) {
            $0.whitelistConfigs = []
        }
        await store.receive(.captureEngine(.whitelistUpdated([]))) {
            $0.captureEngine.whitelist = [:]
        }

        XCTAssertEqual(savedConfigs.value, [[expectedConfig], []])
    }

    @MainActor
    func testAddingRunningApplicationUsesCurrentRunningAppMetadata() async {
        let savedConfigs = LockIsolated([[WhitelistedAppConfig]]())
        let application = RunningApplication(
            bundleIdentifier: "com.example.RunningApp",
            displayName: "Running App",
            processIdentifier: 42
        )
        var state = AppFeature.State()
        state.captureEngine.runningApplications = [application.bundleIdentifier: application]
        state.draftIntervalSeconds = 7

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.capturePermissionClient.request = { .denied }
            $0.whitelistConfigurationClient.save = { configs in
                savedConfigs.withValue { $0.append(configs) }
            }
        }
        store.exhaustivity = .off

        let expectedConfig = WhitelistedAppConfig(
            bundleIdentifier: application.bundleIdentifier,
            displayName: application.displayName,
            captureInterval: 7,
            isEnabled: true
        )

        await store.send(.addRunningApplicationButtonTapped(application.bundleIdentifier)) {
            $0.whitelistConfigs = [expectedConfig]
        }
        await store.receive(.captureEngine(.whitelistUpdated([expectedConfig]))) {
            $0.captureEngine.whitelist = [expectedConfig.bundleIdentifier: expectedConfig]
        }

        XCTAssertEqual(savedConfigs.value, [[expectedConfig]])
    }

    @MainActor
    func testWhitelistEnableAndIntervalChangesPersistAndUpdateCaptureEngine() async {
        let savedConfigs = LockIsolated([[WhitelistedAppConfig]]())
        let config = WhitelistedAppConfig(
            bundleIdentifier: "com.example.ToggleApp",
            displayName: "Toggle App",
            captureInterval: 5,
            isEnabled: true
        )
        var state = AppFeature.State()
        state.whitelistConfigs = [config]

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.whitelistConfigurationClient.save = { configs in
                savedConfigs.withValue { $0.append(configs) }
            }
        }

        let disabledConfig = WhitelistedAppConfig(
            bundleIdentifier: config.bundleIdentifier,
            displayName: config.displayName,
            captureInterval: 5,
            isEnabled: false
        )
        await store.send(.whitelistEnabledChanged(config.bundleIdentifier, false)) {
            $0.whitelistConfigs = [disabledConfig]
        }
        await store.receive(.captureEngine(.whitelistUpdated([disabledConfig]))) {
            $0.captureEngine.whitelist = [disabledConfig.bundleIdentifier: disabledConfig]
        }

        let updatedConfig = WhitelistedAppConfig(
            bundleIdentifier: config.bundleIdentifier,
            displayName: config.displayName,
            captureInterval: 12,
            isEnabled: false
        )
        await store.send(.whitelistIntervalChanged(config.bundleIdentifier, 12)) {
            $0.whitelistConfigs = [updatedConfig]
        }
        await store.receive(.captureEngine(.whitelistUpdated([updatedConfig]))) {
            $0.captureEngine.whitelist = [updatedConfig.bundleIdentifier: updatedConfig]
        }

        XCTAssertEqual(savedConfigs.value, [[disabledConfig], [updatedConfig]])
    }

    @MainActor
    func testRequestCapturePermissionButtonForwardsToCaptureEngine() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.capturePermissionClient.request = { .denied }
        }

        await store.send(.requestCapturePermissionButtonTapped)
        await store.receive(.captureEngine(.requestPermissionButtonTapped))
        await store.receive(.captureEngine(.permissionResolved(.denied, nil))) {
            $0.captureEngine.permissionStatus = .denied
            $0.captureEngine.lastError = CaptureEngineError.screenRecordingPermissionDenied.localizedDescription
            $0.captureEngine.recentDiagnostics = [
                CaptureEngineError.screenRecordingPermissionDenied.localizedDescription,
            ]
        }
    }

    @MainActor
    func testRevealCaptureRootFailureIsShown() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.fileRevealClient.reveal = { _ in }
            $0.fileStorageClient.captureRoot = { throw CaptureEngineError.persistenceUnavailable }
        }

        await store.send(.revealCaptureRootButtonTapped)
        await store.receive(.captureRootRevealFailed(CaptureEngineError.persistenceUnavailable.localizedDescription)) {
            $0.captureRootError = CaptureEngineError.persistenceUnavailable.localizedDescription
        }
    }

    @MainActor
    func testCaptureSessionEventsRefreshViewer() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.persistenceClient.apps = { [] }
            $0.persistenceClient.sessions = { _ in [] }
            $0.persistenceClient.windows = { _ in [] }
            $0.persistenceClient.screenshotsForApp = { _ in [] }
            $0.persistenceClient.screenshotsForWindow = { _ in [] }
        }

        await store.send(.captureEngine(.sessionClosed("com.example.App")))
        await store.receive(.viewer(.refresh))
        await store.receive(.viewer(.appsLoaded([])))
    }
}
