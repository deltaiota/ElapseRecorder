import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class ViewerFeatureMaintenanceTests: XCTestCase {
    @MainActor
    func testIntegritySweepPrunesMissingRecordsAndOrphanFiles() async throws {
        let orphanURL = URL(filePath: "/captures/orphan.heic")
        let missingID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"))

        let deletedRecordIDs = LockIsolated<[UUID]>([])
        let removedFileURLs = LockIsolated<[URL]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.maintenanceServiceClient.integritySweep = { _ in
                deletedRecordIDs.setValue([missingID])
                removedFileURLs.setValue([orphanURL])
                return StorageIntegrityResult(
                    removedRecordCount: 1,
                    removedFileCount: 1,
                    reclaimedBytes: 20
                )
            }
            $0.persistenceClient.apps = { [] }
        }
        store.exhaustivity = .off

        await store.send(.runIntegritySweepButtonTapped) {
            $0.isRunningStorageMaintenance = true
        }
        await store.skipReceivedActions()

        XCTAssertEqual(deletedRecordIDs.value, [missingID])
        XCTAssertEqual(removedFileURLs.value, [orphanURL])
        XCTAssertEqual(
            store.state.storageIntegrityResult,
            StorageIntegrityResult(removedRecordCount: 1, removedFileCount: 1, reclaimedBytes: 20)
        )
        XCTAssertFalse(store.state.isRunningStorageMaintenance)
    }

    @MainActor
    func testBulkDeleteRemovesMatchingSessionsFilesAndRecords() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000B1"))
        let deletedSessionIDs = LockIsolated<[UUID]>([])
        let removedFileURLs = LockIsolated<[URL]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.maintenanceServiceClient.deleteBefore = { cutoff, bundleIdentifier, _ in
                XCTAssertEqual(cutoff, Date(timeIntervalSince1970: 500))
                XCTAssertNil(bundleIdentifier)
                deletedSessionIDs.setValue([sessionID])
                removedFileURLs.setValue([
                    URL(filePath: "/captures/1.heic"),
                    URL(filePath: "/captures/2.heic"),
                ])
                return 1
            }
            $0.persistenceClient.apps = { [] }
        }
        store.exhaustivity = .off

        await store.send(.bulkDeleteRequested(before: Date(timeIntervalSince1970: 500), bundleIdentifier: nil)) {
            $0.isRunningStorageMaintenance = true
        }
        await store.skipReceivedActions()

        XCTAssertEqual(deletedSessionIDs.value, [sessionID])
        XCTAssertEqual(
            removedFileURLs.value,
            [URL(filePath: "/captures/1.heic"), URL(filePath: "/captures/2.heic")]
        )
        XCTAssertFalse(store.state.isRunningStorageMaintenance)
    }

    @MainActor
    func testRetentionPrunesOldestByCountLimitOnly() async {
        // Three ended sessions, 5 screenshots each = 15 total; cap at 8 → delete the two oldest.
        let sessions: [CaptureSessionSummary] = (0 ..< 3).map { index -> CaptureSessionSummary in
            let id = UUID(uuidString: "00000000-0000-0000-0000-00000000C\(index)0\(index)")!
            return CaptureSessionSummary(
                id: id,
                bundleIdentifier: "com.example.App",
                displayName: "App",
                startedAt: Date(timeIntervalSince1970: TimeInterval(100 + index * 100)),
                endedAt: Date(timeIntervalSince1970: TimeInterval(150 + index * 100)),
                windowCount: 1,
                screenshotCount: 5,
                sizeBytes: 50
            )
        }
        let deleted = LockIsolated<[UUID]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.date = .constant(Date(timeIntervalSince1970: 10000))
            $0.capturePreferencesClient.retentionPolicy = {
                RetentionPolicy(maxAge: nil, maxTotalBytes: nil, maxScreenshotCount: 8)
            }
            $0.maintenanceServiceClient.enforceRetention = { policy, now, _ in
                let ids = policy.sessionIDsToPrune(
                    snapshot: RetentionSnapshot(
                        endedSessionsOldestFirst: sessions,
                        activeSizeBytes: 0,
                        activeFrameCount: 0
                    ),
                    now: now
                )
                deleted.setValue(ids)
                return ids.count
            }
            $0.persistenceClient.apps = { [] }
        }
        store.exhaustivity = .off

        await store.send(.enforceRetentionRequested) {
            $0.isEnforcingRetention = true
        }
        await store.skipReceivedActions()

        // Deleting the two oldest leaves 5 <= 8.
        XCTAssertEqual(deleted.value, [sessions[0].id, sessions[1].id])
        XCTAssertFalse(store.state.isEnforcingRetention)
    }

    @MainActor
    func testRetentionNoOpWhenPolicyDisabled() async {
        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.capturePreferencesClient.retentionPolicy = { .none }
        }

        // With no active limits the request is ignored: no state change, no effects.
        await store.send(.enforceRetentionRequested)
    }

    func testRetentionPolicySelectsByAgeAndSize() {
        let now = Date(timeIntervalSince1970: 10000)
        func session(_ number: Int, started: TimeInterval, bytes: Int) -> CaptureSessionSummary {
            CaptureSessionSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D\(number)")!,
                bundleIdentifier: "b", displayName: "b",
                startedAt: Date(timeIntervalSince1970: started), endedAt: Date(timeIntervalSince1970: started + 1),
                windowCount: 1, screenshotCount: 1, sizeBytes: bytes
            )
        }
        let sessions = [
            session(0, started: 1000, bytes: 100), // oldest
            session(1, started: 5000, bytes: 100),
            session(2, started: 9000, bytes: 100), // newest
        ]

        // Age: keep only sessions newer than now-2000s (i.e. started > 8000) → prune 0 and 1.
        let ageOnly = RetentionPolicy(maxAge: 2000, maxTotalBytes: nil, maxScreenshotCount: nil)
        XCTAssertEqual(
            ageOnly.sessionIDsToPrune(endedSessionsOldestFirst: sessions, now: now),
            [sessions[0].id, sessions[1].id]
        )

        // Size: 300 total, cap 150 → delete oldest until <=150 (drop 0 then 1 → 100 left).
        let sizeOnly = RetentionPolicy(maxAge: nil, maxTotalBytes: 150, maxScreenshotCount: nil)
        XCTAssertEqual(
            sizeOnly.sessionIDsToPrune(endedSessionsOldestFirst: sessions, now: now),
            [sessions[0].id, sessions[1].id]
        )

        // No limits → nothing pruned.
        XCTAssertEqual(RetentionPolicy.none.sessionIDsToPrune(endedSessionsOldestFirst: sessions, now: now), [])
    }
}
