import ComposableArchitecture
import Foundation

nonisolated struct MaintenanceEnvironment {
    let persistence: PersistenceClient
    let fileStorage: FileStorageClient
    let storageCoordinator: StorageCoordinatorClient
}

typealias RetentionPolicyProvider = @Sendable () -> RetentionPolicy

nonisolated struct MaintenanceServiceClient {
    var startDailyRetention: @Sendable (
        _ environment: MaintenanceEnvironment,
        _ policy: @escaping RetentionPolicyProvider
    ) async -> Void
    var recover: @Sendable (_ environment: MaintenanceEnvironment) async throws -> Void
    var integritySweep: @Sendable (_ environment: MaintenanceEnvironment) async throws -> StorageIntegrityResult
    var deleteSessions: @Sendable (_ ids: [UUID], _ environment: MaintenanceEnvironment) async throws -> Int
    var deleteBefore: @Sendable (_ cutoff: Date, _ bundleIdentifier: String?, _ environment: MaintenanceEnvironment) async throws -> Int
    var enforceRetention: @Sendable (_ policy: RetentionPolicy, _ now: Date, _ environment: MaintenanceEnvironment) async throws -> Int
}

extension MaintenanceServiceClient: DependencyKey {
    static let liveValue: Self = {
        let service = MaintenanceService()
        return Self(
            startDailyRetention: { environment, policy in
                await service.startDailyRetention(environment: environment, policy: policy)
            },
            recover: { try await service.recover(environment: $0) },
            integritySweep: { try await service.integritySweep(environment: $0) },
            deleteSessions: { try await service.deleteSessions($0, environment: $1) },
            deleteBefore: { try await service.deleteBefore($0, bundleIdentifier: $1, environment: $2) },
            enforceRetention: { try await service.enforceRetention($0, now: $1, environment: $2) }
        )
    }()

    static let testValue = Self(
        startDailyRetention: { _, _ in },
        recover: { _ in },
        integritySweep: { _ in .empty },
        deleteSessions: { _, _ in 0 },
        deleteBefore: { _, _, _ in 0 },
        enforceRetention: { _, _, _ in 0 }
    )
}

extension DependencyValues {
    var maintenanceServiceClient: MaintenanceServiceClient {
        get { self[MaintenanceServiceClient.self] }
        set { self[MaintenanceServiceClient.self] = newValue }
    }
}

/// One process-wide actor owns every destructive maintenance operation. Its explicit FIFO gate is
/// required because actor methods are reentrant across filesystem awaits. The storage lease then
/// drains segment work and prevents a segment commit from racing any tombstone/file deletion.
actor MaintenanceService {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var dailyRetentionTask: Task<Void, Never>?

    func startDailyRetention(
        environment: MaintenanceEnvironment,
        policy: @escaping RetentionPolicyProvider
    ) {
        guard dailyRetentionTask == nil else { return }
        dailyRetentionTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(86400))
                } catch {
                    break
                }
                guard let self else { break }
                _ = try? await self.enforceRetention(
                    policy(),
                    now: Date(),
                    environment: environment
                )
            }
        }
    }

    func recover(environment: MaintenanceEnvironment) async throws {
        try await serialized(environment: environment) {
            try await self.recoverPending(environment: environment)
        }
    }

    func integritySweep(environment: MaintenanceEnvironment) async throws -> StorageIntegrityResult {
        try await serialized(environment: environment) {
            try await self.recoverPending(environment: environment)

            let index = try await environment.persistence.screenshotFileIndex()
            let recordedPaths = Set(index.map(\.path))
            let files = try await environment.fileStorage.captureFileURLs()
            // A partial belongs to a durable segment manifest. Storage recovery, not a generic
            // orphan sweep, decides whether it is resumable or disposable.
            let orphanFiles = files.filter {
                !$0.lastPathComponent.hasSuffix(".partial.mov")
                    && !recordedPaths.contains($0.path(percentEncoded: false))
            }
            let existing = await environment.fileStorage.filterExistingPaths(index.map(\.path))
            let missingIDs = index.lazy.filter { !existing.contains($0.path) }.map(\.id)
            let uniqueMissingIDs = Array(Set(missingIDs))

            try await environment.persistence.deleteScreenshots(uniqueMissingIDs)
            let reclaimed = try await environment.fileStorage.removeFiles(orphanFiles)
            return StorageIntegrityResult(
                removedRecordCount: uniqueMissingIDs.count,
                removedFileCount: orphanFiles.count,
                reclaimedBytes: reclaimed
            )
        }
    }

    func deleteSessions(_ ids: [UUID], environment: MaintenanceEnvironment) async throws -> Int {
        try await serialized(environment: environment) {
            try await self.recoverPending(environment: environment)
            return try await self.prepareAndDelete(ids: ids, environment: environment)
        }
    }

    func deleteBefore(
        _ cutoff: Date,
        bundleIdentifier: String?,
        environment: MaintenanceEnvironment
    ) async throws -> Int {
        try await serialized(environment: environment) {
            try await self.recoverPending(environment: environment)
            let sessions = try await environment.persistence.sessionsStartedBefore(cutoff, bundleIdentifier)
            return try await self.prepareAndDelete(ids: sessions.map(\.id), environment: environment)
        }
    }

    func enforceRetention(
        _ policy: RetentionPolicy,
        now: Date,
        environment: MaintenanceEnvironment
    ) async throws -> Int {
        guard policy.hasAnyLimit else { return 0 }
        return try await serialized(environment: environment) {
            try await self.recoverPending(environment: environment)
            let snapshot = try await environment.persistence.retentionSnapshot()
            let ids = policy.sessionIDsToPrune(snapshot: snapshot, now: now)
            return try await self.prepareAndDelete(ids: ids, environment: environment)
        }
    }

    private func prepareAndDelete(ids: [UUID], environment: MaintenanceEnvironment) async throws -> Int {
        guard !ids.isEmpty,
              let manifest = try await environment.persistence.prepareSessionDeletion(ids)
        else { return 0 }
        try await removeFilesAndFinalize(manifest, environment: environment)
        return manifest.sessions.count
    }

    private func recoverPending(environment: MaintenanceEnvironment) async throws {
        for manifest in try await environment.persistence.pendingSessionDeletions() {
            try await removeFilesAndFinalize(manifest, environment: environment)
        }
    }

    private func removeFilesAndFinalize(
        _ manifest: StorageDeletionManifest,
        environment: MaintenanceEnvironment
    ) async throws {
        _ = try await environment.fileStorage.removeFilesStrict(manifest.fileURLs)
        for session in manifest.sessions {
            try? await environment.fileStorage.deleteSessionCaptures(session.bundleIdentifier, session.id)
        }
        try await environment.persistence.finalizeSessionDeletion(manifest.id)
    }

    private func serialized<T: Sendable>(
        environment: MaintenanceEnvironment,
        operation: () async throws -> T
    ) async throws -> T {
        await acquire()
        let lease = await environment.storageCoordinator.beginMaintenance()
        do {
            let result = try await operation()
            try await environment.storageCoordinator.endMaintenance(lease)
            release()
            return result
        } catch {
            try? await environment.storageCoordinator.endMaintenance(lease)
            release()
            throw error
        }
    }

    private func acquire() async {
        guard isRunning else {
            isRunning = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
