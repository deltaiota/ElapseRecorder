import ComposableArchitecture
@testable import ElapseRecorder
import Foundation
import XCTest

final class MaintenanceServiceTests: XCTestCase {
    func testConcurrentDeletesAreSerializedAndUseStorageLeases() async throws {
        let active = LockIsolated(0)
        let maximumActive = LockIsolated(0)
        let leaseCount = LockIsolated(0)
        let finalized = LockIsolated<[UUID]>([])

        var persistence = PersistenceClient.unimplemented
        persistence.pendingSessionDeletions = { [] }
        persistence.prepareSessionDeletion = { ids in
            guard let sessionID = ids.first else { return nil }
            return StorageDeletionManifest(
                id: sessionID,
                sessions: [StorageDeletionSession(id: sessionID, bundleIdentifier: "example")],
                fileURLs: [URL(filePath: "/tmp/\(sessionID).heic")]
            )
        }
        persistence.finalizeSessionDeletion = { id in finalized.withValue { $0.append(id) } }

        var files = FileStorageClient.liveValue
        files.removeFilesStrict = { _ in
            let current = active.withValue { value -> Int in
                value += 1
                return value
            }
            maximumActive.withValue { $0 = max($0, current) }
            try await Task.sleep(nanoseconds: 10_000_000)
            active.withValue { $0 -= 1 }
            return 1
        }
        files.deleteSessionCaptures = { _, _ in }

        var coordinator = StorageCoordinatorClient.testValue
        coordinator.beginMaintenance = {
            leaseCount.withValue { $0 += 1 }
            return StorageMaintenanceLease(id: UUID())
        }
        coordinator.endMaintenance = { _ in }

        let environment = MaintenanceEnvironment(
            persistence: persistence,
            fileStorage: files,
            storageCoordinator: coordinator
        )
        let service = MaintenanceService()
        let first = UUID()
        let second = UUID()
        async let firstCount = service.deleteSessions([first], environment: environment)
        async let secondCount = service.deleteSessions([second], environment: environment)

        let counts = try await[firstCount, secondCount]
        XCTAssertEqual(counts.sorted(), [1, 1])
        XCTAssertEqual(maximumActive.value, 1)
        XCTAssertEqual(leaseCount.value, 2)
        XCTAssertEqual(Set(finalized.value), Set([first, second]))
    }

    func testRecoveryFinishesDurableTombstoneBeforeOtherMaintenance() async throws {
        let tombstoneID = UUID()
        let sessionID = UUID()
        let manifest = StorageDeletionManifest(
            id: tombstoneID,
            sessions: [StorageDeletionSession(id: sessionID, bundleIdentifier: "example")],
            fileURLs: [URL(filePath: "/tmp/recover.heic")]
        )
        let removed = LockIsolated<[URL]>([])
        let finalized = LockIsolated<[UUID]>([])

        var persistence = PersistenceClient.unimplemented
        persistence.pendingSessionDeletions = { [manifest] }
        persistence.finalizeSessionDeletion = { id in finalized.withValue { $0.append(id) } }

        var files = FileStorageClient.liveValue
        files.removeFilesStrict = { urls in
            removed.withValue { $0.append(contentsOf: urls) }
            return urls.count
        }
        files.deleteSessionCaptures = { _, _ in }

        let environment = MaintenanceEnvironment(
            persistence: persistence,
            fileStorage: files,
            storageCoordinator: .testValue
        )
        try await MaintenanceService().recover(environment: environment)

        XCTAssertEqual(removed.value, manifest.fileURLs)
        XCTAssertEqual(finalized.value, [tombstoneID])
    }

    func testRetentionCountsOpenSessionUsageWithoutEvictingIt() {
        let ended = [
            CaptureSessionSummary(
                id: UUID(),
                bundleIdentifier: "example",
                displayName: "Example",
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2),
                windowCount: 1,
                screenshotCount: 4,
                sizeBytes: 40
            ),
        ]
        let snapshot = RetentionSnapshot(
            endedSessionsOldestFirst: ended,
            activeSizeBytes: 100,
            activeFrameCount: 10
        )
        let policy = RetentionPolicy(maxAge: nil, maxTotalBytes: 120, maxScreenshotCount: nil)

        XCTAssertEqual(
            policy.sessionIDsToPrune(snapshot: snapshot, now: Date(timeIntervalSince1970: 10)),
            [ended[0].id]
        )
    }
}
