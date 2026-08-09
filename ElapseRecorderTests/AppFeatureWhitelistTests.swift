import ComposableArchitecture
@testable import ElapseRecorder
import Foundation
import XCTest

final class AppFeatureWhitelistTests: XCTestCase {
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
    func testAddingMultipleWhitelistConfigsPersistsChanges() async {
        let savedConfigs = LockIsolated([[WhitelistedAppConfig]]())
        let firstConfig = WhitelistedAppConfig(
            bundleIdentifier: "com.example.FirstApp",
            displayName: "First App",
            captureInterval: 5,
            isEnabled: true
        )
        let secondConfig = WhitelistedAppConfig(
            bundleIdentifier: "com.example.SecondApp",
            displayName: "Second App",
            captureInterval: 9,
            isEnabled: true
        )

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.whitelistConfigurationClient.save = { configs in
                savedConfigs.withValue { $0.append(configs) }
            }
        }

        await store.send(.addWhitelistConfigsButtonTapped([firstConfig, secondConfig])) {
            $0.whitelistConfigs = [firstConfig, secondConfig]
        }
        await store.receive(.captureEngine(.whitelistUpdated([firstConfig, secondConfig]))) {
            $0.captureEngine.whitelist = [
                firstConfig.bundleIdentifier: firstConfig,
                secondConfig.bundleIdentifier: secondConfig,
            ]
        }

        XCTAssertEqual(savedConfigs.value, [[firstConfig, secondConfig]])
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
    func testViewerAppWhitelistActionsPersistChanges() async {
        let savedConfigs = LockIsolated([[WhitelistedAppConfig]]())
        let config = WhitelistedAppConfig(
            bundleIdentifier: "com.example.ViewerApp",
            displayName: "Viewer App",
            captureInterval: 5,
            isEnabled: true
        )
        let app = AppCaptureSummary(
            bundleIdentifier: config.bundleIdentifier,
            displayName: config.displayName,
            sessionCount: 2,
            screenshotCount: 10,
            lastCapturedAt: Date(timeIntervalSince1970: 100)
        )
        var state = AppFeature.State()
        state.whitelistConfigs = [config]
        state.captureEngine.whitelist = [config.bundleIdentifier: config]
        state.draftIntervalSeconds = 9

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.whitelistConfigurationClient.save = { configs in
                savedConfigs.withValue { $0.append(configs) }
            }
        }
        store.exhaustivity = .off

        await store.send(.removeViewerAppFromWhitelistButtonTapped(app))
        await store.receive(.captureEngine(.whitelistUpdated([])))
        XCTAssertEqual(store.state.whitelistConfigs, [])
        XCTAssertEqual(store.state.captureEngine.whitelist, [:])

        let readdedConfig = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 9,
            isEnabled: true
        )
        await store.send(.addViewerAppToWhitelistButtonTapped(app))
        await store.receive(.captureEngine(.whitelistUpdated([readdedConfig])))
        XCTAssertEqual(store.state.whitelistConfigs, [readdedConfig])
        XCTAssertEqual(store.state.captureEngine.whitelist, [readdedConfig.bundleIdentifier: readdedConfig])

        XCTAssertEqual(savedConfigs.value, [[], [readdedConfig]])
    }
}
