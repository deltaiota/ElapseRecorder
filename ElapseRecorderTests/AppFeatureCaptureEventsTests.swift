import ComposableArchitecture
@testable import ElapseRecorder
import Foundation
import XCTest

final class AppFeatureCaptureEventsTests: XCTestCase {
    @MainActor
    func testDeletingViewerAppRemovesWhitelistFilesAndMetadataThenRefreshes() async {
        let config = WhitelistedAppConfig(
            bundleIdentifier: "com.example.DeleteApp",
            displayName: "Delete App",
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
        let savedConfigs = LockIsolated([[WhitelistedAppConfig]]())
        let deletedCaptureApps = LockIsolated([String]())
        let deletedMetadataApps = LockIsolated([String]())
        var state = AppFeature.State()
        state.whitelistConfigs = [config]
        state.captureEngine.whitelist = [config.bundleIdentifier: config]

        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.fileStorageClient.deleteAppCaptures = { bundleIdentifier in
                deletedCaptureApps.withValue { $0.append(bundleIdentifier) }
            }
            $0.persistenceClient.deleteApp = { bundleIdentifier in
                deletedMetadataApps.withValue { $0.append(bundleIdentifier) }
            }
            $0.persistenceClient.apps = { [] }
            $0.whitelistConfigurationClient.save = { configs in
                savedConfigs.withValue { $0.append(configs) }
            }
        }
        store.exhaustivity = .off

        await store.send(.deleteViewerAppButtonTapped(app))
        await store.receive(.captureEngine(.whitelistUpdated([])))
        await store.receive(.viewer(.refresh))
        await store.receive(.viewer(.appsLoaded([])))
        XCTAssertEqual(store.state.whitelistConfigs, [])
        XCTAssertEqual(store.state.captureEngine.whitelist, [:])

        XCTAssertEqual(savedConfigs.value, [[]])
        XCTAssertEqual(deletedCaptureApps.value, [app.bundleIdentifier])
        XCTAssertEqual(deletedMetadataApps.value, [app.bundleIdentifier])
    }

    @MainActor
    func testRecordedScreenshotUpdatesViewerWithoutFullRefresh() async {
        let application = RunningApplication(
            bundleIdentifier: "com.example.ArtApp",
            displayName: "Art App",
            processIdentifier: 42
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: application.bundleIdentifier,
            displayName: application.displayName,
            captureInterval: 1,
            isEnabled: true
        )
        let session = CaptureSession(
            id: UUID(),
            bundleIdentifier: application.bundleIdentifier,
            displayName: application.displayName,
            processIdentifier: application.processIdentifier,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let record = ScreenshotRecord(
            id: UUID(),
            windowID: UUID(),
            sessionID: session.id,
            capturedAt: Date(timeIntervalSince1970: 101),
            fileURL: URL(filePath: "/tmp/frame.heic"),
            fileSizeBytes: 1
        )
        var state = AppFeature.State()
        state.captureEngine.activeSessions[application.bundleIdentifier] = .init(
            application: application,
            config: config,
            session: session
        )
        let store = TestStore(initialState: state) {
            AppFeature()
        }

        await store.send(.captureEngine(.screenshotRecorded(record)))
        await store.receive(
            .viewer(.captureScreenshotRecorded(record, bundleIdentifier: application.bundleIdentifier))
        )
    }

    @MainActor
    func testCaptureSessionEventsRefreshViewerAndRunMaintenance() async {
        let maintenanceRuns = LockIsolated(0)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.persistenceClient.apps = { [] }
            $0.maintenanceServiceClient.recover = { _ in }
            $0.maintenanceServiceClient.enforceRetention = { _, _, _ in
                maintenanceRuns.withValue { $0 += 1 }
                return 0
            }
        }
        store.exhaustivity = .off

        await store.send(.captureEngine(.sessionClosed("com.example.App")))
        await store.skipReceivedActions()
        XCTAssertEqual(maintenanceRuns.value, 1)
    }
}
