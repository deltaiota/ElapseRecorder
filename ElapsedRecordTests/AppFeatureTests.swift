import ComposableArchitecture
@testable import ElapsedRecord
import Foundation
import XCTest

final class AppFeatureTests: XCTestCase {
    @MainActor
    func testLoadedWhitelistUpdatesTestHarnessAndCaptureEngine() async {
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
            $0.testBundleIdentifier = config.bundleIdentifier
            $0.testDisplayName = config.displayName
            $0.testIntervalSeconds = config.captureInterval
            $0.isTestCaptureEnabled = true
        }
        await store.receive(.captureEngine(.whitelistUpdated([config]))) {
            $0.captureEngine.whitelist = [config.bundleIdentifier: config]
        }
    }

    @MainActor
    func testStartAndStopTestCapturePersistWhitelistChanges() async {
        let savedConfigs = LockIsolated([[WhitelistedAppConfig]]())
        var state = AppFeature.State()
        state.testBundleIdentifier = "com.example.CaptureMe"
        state.testDisplayName = "Capture Me"
        state.testIntervalSeconds = 3

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

        await store.send(.startTestCaptureButtonTapped) {
            $0.isTestCaptureEnabled = true
        }
        await store.receive(.captureEngine(.whitelistUpdated([expectedConfig]))) {
            $0.captureEngine.whitelist = [expectedConfig.bundleIdentifier: expectedConfig]
        }

        await store.send(.stopTestCaptureButtonTapped) {
            $0.isTestCaptureEnabled = false
        }
        await store.receive(.captureEngine(.whitelistUpdated([]))) {
            $0.captureEngine.whitelist = [:]
        }

        XCTAssertEqual(savedConfigs.value, [[expectedConfig], []])
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
