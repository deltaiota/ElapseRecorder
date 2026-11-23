import ComposableArchitecture
import CoreGraphics
import Foundation

nonisolated struct StorageCoordinatorClient {
    var events: @Sendable () async -> AsyncStream<StorageCoordinatorEvent>
    var enqueue: @Sendable (_ frame: CapturedFrameEnvelope) async -> StorageEnqueueResult
    var flushSession: @Sendable (_ handle: RecordingSessionHandle) async throws -> Void
    var recover: @Sendable () async -> Void
    var setCompactionSuspended: @Sendable (_ suspended: Bool) async -> Void
    var beginMaintenance: @Sendable () async -> StorageMaintenanceLease
    var endMaintenance: @Sendable (_ lease: StorageMaintenanceLease) async throws -> Void
}

extension StorageCoordinatorClient: DependencyKey {
    static let liveValue = live(environment: StorageCoordinator.Environment(
        configuration: .defaultValue,
        persistence: .liveValue,
        fileStorage: .liveValue,
        imageEncoder: .liveValue,
        segmentWriter: .liveValue,
        segmentQuality: CapturePreferencesClient.liveValue.segmentHEVCQuality,
        now: { Date() },
        makeID: { UUID() }
    ))

    static let testValue = Self(
        events: {
            AsyncStream { continuation in continuation.finish() }
        },
        enqueue: { frame in .accepted(frameID: frame.id) },
        flushSession: { _ in },
        recover: {},
        setCompactionSuspended: { _ in },
        beginMaintenance: { StorageMaintenanceLease(id: UUID()) },
        endMaintenance: { _ in }
    )

    nonisolated static func live(environment: StorageCoordinator.Environment) -> Self {
        let coordinator = StorageCoordinator(environment: environment)
        return Self(
            events: { await coordinator.events() },
            enqueue: { await coordinator.enqueue($0) },
            flushSession: { try await coordinator.flushSession($0) },
            recover: { await coordinator.recover() },
            setCompactionSuspended: { await coordinator.setCompactionSuspended($0) },
            beginMaintenance: { await coordinator.beginMaintenance() },
            endMaintenance: { try await coordinator.endMaintenance($0) }
        )
    }
}

extension DependencyValues {
    var storageCoordinatorClient: StorageCoordinatorClient {
        get { self[StorageCoordinatorClient.self] }
        set { self[StorageCoordinatorClient.self] = newValue }
    }
}

actor StorageCoordinator {
    struct Environment {
        var configuration: StorageCoordinatorConfiguration
        var persistence: PersistenceClient
        var fileStorage: FileStorageClient
        var imageEncoder: ImageEncodingClient
        var segmentWriter: SegmentVideoWriterClient
        var segmentQuality: @Sendable () -> Double
        var now: @Sendable () -> Date
        var makeID: @Sendable () -> UUID
    }

    struct WindowKey: Hashable {
        var sessionID: UUID
        var windowID: UUID
    }

    let configuration: StorageCoordinatorConfiguration
    let persistence: PersistenceClient
    let fileStorage: FileStorageClient
    let imageEncoder: ImageEncodingClient
    let segmentWriter: SegmentVideoWriterClient
    let segmentQuality: @Sendable () -> Double
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID
    let workerID: UUID

    var continuations: [UUID: AsyncStream<StorageCoordinatorEvent>.Continuation] = [:]
    var queue: [CapturedFrameEnvelope] = []
    var processingFrame: CapturedFrameEnvelope?
    var isDrainingQueue = false
    var activeFlushCount = 0
    var accumulators: [WindowKey: [StoredSpoolFrame]] = [:]
    var deferredFrames: [WindowKey: [StoredSpoolFrame]] = [:]
    var sealingWindows = Set<WindowKey>()
    var activeSealRetryCount = 0
    var spoolBytes = 0
    var knownSpoolBytes: [URL: Int] = [:]
    var isSegmentWorkerRunning = false
    var segmentWorkerTask: Task<Void, Never>?
    var restartSegmentWorkerWhenStopped = false
    var isSegmentRetryScheduled = false
    var isCompactionSuspended = false
    var failedJobsBySession: [UUID: Set<UUID>] = [:]
    var sealFailureIDsByWindow: [WindowKey: Set<UUID>] = [:]
    var sealRetryScheduled = Set<WindowKey>()
    var maintenanceLease: StorageMaintenanceLease?
    var activeDegradations = Set<StorageDegradation>()
    var isHealthProbeScheduled = false
    var isHealthProbeRunning = false
    var healthProbeGeneration: UInt64 = 0
    var isRecoveryRunning = false
    var recoveryCompletionGeneration: UInt64 = 0
    var requiredSpoolHeadroom = 0
    var requiredDiskHeadroom: Int64 = 0
    var stateGeneration: UInt64 = 0
    var stateWaiters: [CheckedContinuation<Void, Never>] = []

    init(environment: Environment) {
        configuration = environment.configuration
        persistence = environment.persistence
        fileStorage = environment.fileStorage
        imageEncoder = environment.imageEncoder
        segmentWriter = environment.segmentWriter
        segmentQuality = environment.segmentQuality
        now = environment.now
        makeID = environment.makeID
        workerID = environment.makeID()
    }

    func signalStateTransition() {
        stateGeneration &+= 1
        let waiters = stateWaiters
        stateWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForStateTransition(after observedGeneration: UInt64) async {
        guard stateGeneration == observedGeneration else { return }
        await withCheckedContinuation { continuation in
            guard stateGeneration == observedGeneration else {
                continuation.resume()
                return
            }
            stateWaiters.append(continuation)
        }
    }

    func events() -> AsyncStream<StorageCoordinatorEvent> {
        let id = makeID()
        let (stream, continuation) = AsyncStream<StorageCoordinatorEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func enqueue(_ frame: CapturedFrameEnvelope) -> StorageEnqueueResult {
        guard maintenanceLease == nil else {
            degrade(.maintenanceInProgress)
            return .backpressured(capacity: configuration.queueCapacity)
        }
        let occupied = queue.count + (processingFrame == nil ? 0 : 1)
        guard occupied < configuration.queueCapacity else {
            degrade(.queueFull(capacity: configuration.queueCapacity))
            return .backpressured(capacity: configuration.queueCapacity)
        }
        queue.append(frame)
        if !isDrainingQueue {
            isDrainingQueue = true
            Task(priority: .background) { await self.drainQueue() }
        }
        return .accepted(frameID: frame.id)
    }

    func flushSession(_ handle: RecordingSessionHandle) async throws {
        while maintenanceLease != nil {
            let observedGeneration = stateGeneration
            await waitForStateTransition(after: observedGeneration)
        }
        activeFlushCount += 1
        signalStateTransition()
        defer {
            activeFlushCount -= 1
            signalStateTransition()
        }

        while processingFrame?.handle.sessionID == handle.sessionID
            || queue.contains(where: { $0.handle.sessionID == handle.sessionID })
        {
            let observedGeneration = stateGeneration
            await waitForStateTransition(after: observedGeneration)
        }

        var creationFailed = false
        let keys = Set(
            accumulators.keys.filter { $0.sessionID == handle.sessionID }
                + deferredFrames.keys.filter { $0.sessionID == handle.sessionID }
        )
        for key in keys {
            while accumulators[key]?.isEmpty == false || deferredFrames[key]?.isEmpty == false {
                guard await attemptSeal(key) else {
                    creationFailed = true
                    break
                }
            }
        }
        guard !creationFailed else {
            throw StorageCoordinatorError.sessionFlushFailed(handle.sessionID)
        }
    }

    func recover() async {
        while true {
            if isRecoveryRunning {
                let observedRecoveryGeneration = recoveryCompletionGeneration
                while recoveryCompletionGeneration == observedRecoveryGeneration {
                    let observedStateGeneration = stateGeneration
                    await waitForStateTransition(after: observedStateGeneration)
                }
                return
            }
            guard maintenanceLease == nil, !isHealthProbeRunning else {
                let observedGeneration = stateGeneration
                await waitForStateTransition(after: observedGeneration)
                continue
            }
            isRecoveryRunning = true
            segmentWorkerTask?.cancel()
            signalStateTransition()
            break
        }
        defer {
            isRecoveryRunning = false
            recoveryCompletionGeneration &+= 1
            signalStateTransition()
            startSegmentWorkerIfNeeded()
        }
        do {
            while isSegmentWorkerRunning {
                let observedGeneration = stateGeneration
                await waitForStateTransition(after: observedGeneration)
            }
            try await recoverCommittedSpoolCleanup()
            try await recoverSpoolJournal()
            spoolBytes = try await persistence.spoolByteCount()
            knownSpoolBytes.removeAll(keepingCapacity: true)
            try await recoverSegmentJournal()
            while true {
                let recoveredCount = try await loadPendingFrames()
                var sealedAny = false
                for key in Array(accumulators.keys) {
                    sealedAny = await attemptSeal(key) || sealedAny
                }
                guard recoveredCount == configuration.recoveryBatchSize, sealedAny else { break }
            }
            resolve {
                if case .recoveryFailed = $0 { true } else { false }
            }
        } catch {
            degrade(.recoveryFailed(message: String(describing: error)))
        }
    }

    func beginMaintenance() async -> StorageMaintenanceLease {
        while maintenanceLease != nil {
            let observedGeneration = stateGeneration
            await waitForStateTransition(after: observedGeneration)
        }
        let lease = StorageMaintenanceLease(id: makeID())
        maintenanceLease = lease
        signalStateTransition()
        while isDrainingQueue || processingFrame != nil || !queue.isEmpty
            || activeFlushCount > 0 || activeSealRetryCount > 0 || !sealingWindows.isEmpty
            || isSegmentWorkerRunning || isHealthProbeRunning || isRecoveryRunning
        {
            let observedGeneration = stateGeneration
            await waitForStateTransition(after: observedGeneration)
        }
        return lease
    }

    func endMaintenance(_ lease: StorageMaintenanceLease) throws {
        guard maintenanceLease == lease else {
            throw StorageCoordinatorError.maintenanceLeaseInvalid
        }
        maintenanceLease = nil
        signalStateTransition()
        resolve { $0 == .maintenanceInProgress }
        startSegmentWorkerIfNeeded()
    }
}
