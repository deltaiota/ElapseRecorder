import ComposableArchitecture
@testable import ElapseRecorder
import Foundation
import XCTest

final class AppFeatureStartupTests: XCTestCase {
    @MainActor
    func testTaskRunsStartupEffectsOnlyOnce() async {
        let recordingStartCount = LockIsolated(0)
        let loadWhitelistCount = LockIsolated(0)
        let dailyRetentionStartCount = LockIsolated(0)

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.dateClient.now = { Date(timeIntervalSince1970: 1000) }
            $0.persistenceClient.apps = { [] }
            $0.maintenanceServiceClient.startDailyRetention = { _, _ in
                dailyRetentionStartCount.withValue { $0 += 1 }
            }
            $0.whitelistConfigurationClient.load = {
                loadWhitelistCount.withValue { $0 += 1 }
                return []
            }
            $0.recordingServiceClient.start = {
                recordingStartCount.withValue { $0 += 1 }
                return AsyncStream { $0.finish() }
            }
            $0.workspaceClient.events = {
                AsyncStream { continuation in
                    continuation.finish()
                }
            }
            $0.workspaceClient.runningApplications = { [] }
        }
        store.exhaustivity = .off

        await store.send(.task) {
            $0.hasStarted = true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        await store.send(.task)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(recordingStartCount.value, 1)
        XCTAssertEqual(loadWhitelistCount.value, 1)
        XCTAssertEqual(dailyRetentionStartCount.value, 1)
    }

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
    func testRequestCapturePermissionButtonForwardsToCaptureEngine() async {
        let requestCount = LockIsolated(0)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.recordingServiceClient.requestPermission = {
                requestCount.withValue { $0 += 1 }
            }
        }
        store.exhaustivity = .off

        await store.send(.requestCapturePermissionButtonTapped)
        await store.receive(.captureEngine(.requestPermissionButtonTapped))
        XCTAssertEqual(requestCount.value, 1)
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
}
