import ComposableArchitecture
import CoreGraphics
import Foundation

nonisolated struct StorageCoordinatorClient {
    var events: @Sendable () async -> AsyncStream<StorageCoordinatorEvent>
    var enqueue: @Sendable (_ frame: CapturedFrameEnvelope) async -> StorageEnqueueResult
    var flushSession: @Sendable (_ handle: RecordingSessionHandle) async throws -> Void
    var recover: @Sendable () async -> Void
    var beginMaintenance: @Sendable () async -> StorageMaintenanceLease
    var endMaintenance: @Sendable (_ lease: StorageMaintenanceLease) async throws -> Void
}

extension StorageCoordinatorClient: DependencyKey {
    static let liveValue = live(
        configuration: .defaultValue,
        persistence: .liveValue,
        fileStorage: .liveValue,
        imageEncoder: .liveValue,
        segmentWriter: .liveValue,
        segmentQuality: CapturePreferencesClient.liveValue.segmentHEVCQuality,
        now: { Date() },
        makeID: { UUID() }
    )

    static let testValue = Self(
        events: {
            AsyncStream { continuation in continuation.finish() }
        },
        enqueue: { frame in .accepted(frameID: frame.id) },
        flushSession: { _ in },
        recover: {},
        beginMaintenance: { StorageMaintenanceLease(id: UUID()) },
        endMaintenance: { _ in }
    )

    nonisolated static func live(
        configuration: StorageCoordinatorConfiguration,
        persistence: PersistenceClient,
        fileStorage: FileStorageClient,
        imageEncoder: ImageEncodingClient,
        segmentWriter: SegmentVideoWriterClient,
        segmentQuality: @escaping @Sendable () -> Double,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID
    ) -> Self {
        let coordinator = StorageCoordinator(
            configuration: configuration,
            persistence: persistence,
            fileStorage: fileStorage,
            imageEncoder: imageEncoder,
            segmentWriter: segmentWriter,
            segmentQuality: segmentQuality,
            now: now,
            makeID: makeID
        )
        return Self(
            events: { await coordinator.events() },
            enqueue: { await coordinator.enqueue($0) },
            flushSession: { try await coordinator.flushSession($0) },
            recover: { await coordinator.recover() },
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

private actor StorageCoordinator {
    private struct WindowKey: Hashable {
        var sessionID: UUID
        var windowID: UUID
    }

    private let configuration: StorageCoordinatorConfiguration
    private let persistence: PersistenceClient
    private let fileStorage: FileStorageClient
    private let imageEncoder: ImageEncodingClient
    private let segmentWriter: SegmentVideoWriterClient
    private let segmentQuality: @Sendable () -> Double
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let workerID: UUID

    private var continuations: [UUID: AsyncStream<StorageCoordinatorEvent>.Continuation] = [:]
    private var queue: [CapturedFrameEnvelope] = []
    private var processingFrame: CapturedFrameEnvelope?
    private var isDrainingQueue = false
    private var accumulators: [WindowKey: [StoredSpoolFrame]] = [:]
    private var deferredFrames: [WindowKey: [StoredSpoolFrame]] = [:]
    private var spoolBytes = 0
    private var knownSpoolBytes: [URL: Int] = [:]
    private var isSegmentWorkerRunning = false
    private var isSegmentRetryScheduled = false
    private var failedJobsBySession: [UUID: Set<UUID>] = [:]
    private var sealFailureIDsByWindow: [WindowKey: Set<UUID>] = [:]
    private var sealRetryScheduled = Set<WindowKey>()
    private var maintenanceLease: StorageMaintenanceLease?
    private var activeDegradations = Set<StorageDegradation>()
    private var isHealthProbeScheduled = false
    private var isHealthProbeRunning = false
    private var isRecoveryRunning = false
    private var requiredSpoolHeadroom = 0
    private var requiredDiskHeadroom: Int64 = 0

    init(
        configuration: StorageCoordinatorConfiguration,
        persistence: PersistenceClient,
        fileStorage: FileStorageClient,
        imageEncoder: ImageEncodingClient,
        segmentWriter: SegmentVideoWriterClient,
        segmentQuality: @escaping @Sendable () -> Double,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID
    ) {
        self.configuration = configuration
        self.persistence = persistence
        self.fileStorage = fileStorage
        self.imageEncoder = imageEncoder
        self.segmentWriter = segmentWriter
        self.segmentQuality = segmentQuality
        self.now = now
        self.makeID = makeID
        workerID = makeID()
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
            Task { await self.drainQueue() }
        }
        return .accepted(frameID: frame.id)
    }

    func flushSession(_ handle: RecordingSessionHandle) async throws {
        while maintenanceLease != nil {
            await Task.yield()
        }
        while processingFrame?.handle.sessionID == handle.sessionID
            || queue.contains(where: { $0.handle.sessionID == handle.sessionID })
        {
            await Task.yield()
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
        startSegmentWorkerIfNeeded()
        while isSegmentWorkerRunning {
            await Task.yield()
        }
        let jobsFailed = failedJobsBySession[handle.sessionID]?.isEmpty == false
        guard !creationFailed, !jobsFailed else {
            throw StorageCoordinatorError.sessionFlushFailed(handle.sessionID)
        }
    }

    func recover() async {
        while maintenanceLease != nil {
            await Task.yield()
        }
        isRecoveryRunning = true
        defer { isRecoveryRunning = false }
        do {
            try await recoverCommittedSpoolCleanup()
            try await recoverSpoolJournal()
            spoolBytes = try await persistence.spoolByteCount()
            knownSpoolBytes.removeAll(keepingCapacity: true)
            try await recoverSegmentJournal()
            while true {
                let recoveredCount = try await loadPendingFrames()
                var sealedAny = false
                let keys = Array(accumulators.keys)
                for key in keys {
                    if await attemptSeal(key) {
                        sealedAny = true
                    }
                }
                startSegmentWorkerIfNeeded()
                while isSegmentWorkerRunning {
                    await Task.yield()
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
            await Task.yield()
        }
        let lease = StorageMaintenanceLease(id: makeID())
        maintenanceLease = lease
        while isDrainingQueue || processingFrame != nil || !queue.isEmpty
            || isSegmentWorkerRunning || isHealthProbeRunning || isRecoveryRunning
        {
            await Task.yield()
        }
        return lease
    }

    func endMaintenance(_ lease: StorageMaintenanceLease) throws {
        guard maintenanceLease == lease else {
            throw StorageCoordinatorError.maintenanceLeaseInvalid
        }
        maintenanceLease = nil
        resolve { $0 == .maintenanceInProgress }
        startSegmentWorkerIfNeeded()
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: StorageCoordinatorEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func degrade(_ reason: StorageDegradation) {
        if activeDegradations.insert(reason).inserted {
            emit(.storageDegraded(reason))
        }
        switch reason {
        case .spoolWriteFailed, .metadataCommitFailed, .spoolCapacityExceeded,
             .insufficientFreeSpace, .recoveryFailed:
            scheduleHealthProbe()
        case .queueFull, .segmentFailed, .maintenanceInProgress:
            break
        }
    }

    private func resolve(_ predicate: (StorageDegradation) -> Bool) {
        let wasDegraded = !activeDegradations.isEmpty
        activeDegradations = Set(activeDegradations.filter { !predicate($0) })
        if wasDegraded, activeDegradations.isEmpty {
            emit(.storageResumed)
        }
    }

    private func resolveFramePathDegradations() {
        resolve {
            switch $0 {
            case .queueFull, .spoolWriteFailed, .metadataCommitFailed, .insufficientFreeSpace:
                true
            case .spoolCapacityExceeded:
                requiredSpoolHeadroom <= configuration.maximumSpoolBytes
                    && spoolBytes <= configuration.maximumSpoolBytes - requiredSpoolHeadroom
            case .segmentFailed, .recoveryFailed, .maintenanceInProgress:
                false
            }
        }
    }

    private func scheduleHealthProbe() {
        guard !isHealthProbeScheduled else { return }
        isHealthProbeScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.performHealthProbe()
        }
    }

    private func performHealthProbe() async {
        isHealthProbeScheduled = false
        guard maintenanceLease == nil else {
            scheduleHealthProbe()
            return
        }
        isHealthProbeRunning = true
        defer { isHealthProbeRunning = false }
        do {
            try await fileStorage.probeWritable()
            try await recoverSpoolJournal()
            let persistedSpoolBytes = try await persistence.spoolByteCount()
            let available = try await fileStorage.availableCapacity()
            spoolBytes = persistedSpoolBytes
            let hasSpoolHeadroom = requiredSpoolHeadroom <= configuration.maximumSpoolBytes
                && spoolBytes <= configuration.maximumSpoolBytes - requiredSpoolHeadroom
            let requiredDiskBytes = configuration.minimumFreeDiskBytes + requiredDiskHeadroom
            guard hasSpoolHeadroom, available >= requiredDiskBytes else {
                scheduleHealthProbe()
                return
            }
            requiredSpoolHeadroom = 0
            requiredDiskHeadroom = 0
            resolve {
                switch $0 {
                case .spoolWriteFailed, .metadataCommitFailed, .spoolCapacityExceeded,
                     .insufficientFreeSpace, .recoveryFailed:
                    true
                case .queueFull, .segmentFailed, .maintenanceInProgress:
                    false
                }
            }
            startSegmentWorkerIfNeeded()
        } catch {
            scheduleHealthProbe()
        }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let frame = queue.removeFirst()
            processingFrame = frame
            await persist(frame)
            processingFrame = nil
        }
        isDrainingQueue = false
        resolve { if case .queueFull = $0 { true } else { false } }
    }

    private func persist(_ envelope: CapturedFrameEnvelope) async {
        let spoolURL: URL
        let data: Data
        let isSegmentEligible = envelope.encodingOptions.format == .heic
        do {
            spoolURL = try fileStorage.spoolFrameURL(
                envelope.handle,
                envelope.window.windowID,
                envelope.id,
                envelope.encodingOptions.format
            )
            data = try await imageEncoder.encode(
                CapturedImage(cgImage: envelope.image.cgImage),
                envelope.encodingOptions
            )
        } catch {
            if isSegmentEligible { requiredSpoolHeadroom = max(requiredSpoolHeadroom, 1) }
            requiredDiskHeadroom = max(requiredDiskHeadroom, 1)
            degrade(.spoolWriteFailed(frameID: envelope.id, message: String(describing: error)))
            return
        }

        let transientHeadroom = isSegmentEligible ? data.count : 0
        if isSegmentEligible,
           data.count > configuration.maximumSpoolBytes
           || spoolBytes > configuration.maximumSpoolBytes - data.count
        {
            requiredSpoolHeadroom = max(requiredSpoolHeadroom, data.count)
            degrade(.spoolCapacityExceeded(maximumBytes: configuration.maximumSpoolBytes))
            await relieveSpoolPressure()
            return
        }
        do {
            let available = try await fileStorage.availableCapacity()
            let required = Int64(data.count) + configuration.minimumFreeDiskBytes
            guard available >= required else {
                requiredSpoolHeadroom = max(requiredSpoolHeadroom, transientHeadroom)
                requiredDiskHeadroom = max(requiredDiskHeadroom, Int64(data.count))
                degrade(.insufficientFreeSpace(requiredBytes: required, availableBytes: available))
                await relieveSpoolPressure()
                return
            }
        } catch {
            requiredSpoolHeadroom = max(requiredSpoolHeadroom, transientHeadroom)
            requiredDiskHeadroom = max(requiredDiskHeadroom, Int64(data.count))
            degrade(.spoolWriteFailed(frameID: envelope.id, message: String(describing: error)))
            return
        }

        let registration = SpoolFrameRegistration(
            id: envelope.id,
            sessionID: envelope.handle.sessionID,
            windowID: envelope.window.windowID,
            bundleIdentifier: envelope.handle.bundleIdentifier,
            processIdentifier: envelope.handle.processIdentifier,
            generation: envelope.handle.generation,
            cycleSequence: envelope.cycleSequence,
            scheduledOffsetNanoseconds: envelope.scheduledOffsetNanoseconds,
            requestStartedAt: envelope.requestStartedAt,
            completedAt: envelope.completedAt,
            spoolURL: spoolURL,
            format: envelope.encodingOptions.format,
            pixelWidth: envelope.image.cgImage.width,
            pixelHeight: envelope.image.cgImage.height,
            perceptualHash: envelope.perceptualHash
        )
        do {
            try await persistence.registerSpoolFrame(registration)
        } catch {
            requiredSpoolHeadroom = max(requiredSpoolHeadroom, transientHeadroom)
            requiredDiskHeadroom = max(requiredDiskHeadroom, Int64(data.count))
            degrade(.metadataCommitFailed(frameID: envelope.id, message: String(describing: error)))
            return
        }

        do {
            guard !(await fileStorage.fileExists(spoolURL)) else {
                throw StorageCoordinatorError.readyAssetAlreadyExists(spoolURL)
            }
            _ = try await fileStorage.write(data, spoolURL)
        } catch {
            requiredSpoolHeadroom = max(requiredSpoolHeadroom, transientHeadroom)
            requiredDiskHeadroom = max(requiredDiskHeadroom, Int64(data.count))
            try? await persistence.failSpoolFrame(envelope.id, String(describing: error))
            degrade(.spoolWriteFailed(frameID: envelope.id, message: String(describing: error)))
            return
        }

        let stored: StoredSpoolFrame
        do {
            stored = try await persistence.markSpoolFrameReady(envelope.id, data.count)
        } catch {
            requiredSpoolHeadroom = max(requiredSpoolHeadroom, transientHeadroom)
            requiredDiskHeadroom = max(requiredDiskHeadroom, Int64(data.count))
            // Keep both the registration and published spool. Startup recovery adopts this exact URL.
            degrade(.metadataCommitFailed(frameID: envelope.id, message: String(describing: error)))
            return
        }
        account(stored)
        await accumulate(stored)
        emit(.frameCommitted(stored))
        if isSegmentEligible { requiredSpoolHeadroom = 0 }
        requiredDiskHeadroom = 0
        resolveFramePathDegradations()
    }

    private func relieveSpoolPressure() async {
        let keys = Array(accumulators.keys)
        for key in keys {
            _ = await attemptSeal(key)
        }
        startSegmentWorkerIfNeeded()
    }

    private func account(_ frame: StoredSpoolFrame) {
        guard frame.format == .heic, knownSpoolBytes[frame.spoolURL] == nil else { return }
        knownSpoolBytes[frame.spoolURL] = frame.byteCount
        spoolBytes += frame.byteCount
    }

    private func accumulate(_ frame: StoredSpoolFrame) async {
        guard frame.format == .heic else { return }
        let key = WindowKey(sessionID: frame.sessionID, windowID: frame.windowID)
        if accumulators[key]?.contains(where: { $0.id == frame.id }) == true { return }
        if let existing = accumulators[key]?.first,
           existing.pixelWidth != frame.pixelWidth || existing.pixelHeight != frame.pixelHeight
        {
            guard await attemptSeal(key) else {
                deferFrame(frame, for: key)
                return
            }
        }
        if let existing = accumulators[key], !existing.isEmpty,
           wouldExceedSegment(existing, adding: frame)
        {
            guard await attemptSeal(key) else {
                deferFrame(frame, for: key)
                return
            }
        }
        accumulators[key, default: []].append(frame)
        if shouldSeal(accumulators[key] ?? []) {
            _ = await attemptSeal(key)
        }
    }

    private func deferFrame(_ frame: StoredSpoolFrame, for key: WindowKey) {
        guard deferredFrames[key]?.contains(where: { $0.id == frame.id }) != true else { return }
        deferredFrames[key, default: []].append(frame)
    }

    private func shouldSeal(_ frames: [StoredSpoolFrame]) -> Bool {
        guard let first = frames.first, let last = frames.last else { return false }
        let totalBytes = frames.reduce(into: 0) { $0 += $1.byteCount }
        let duration = max(0, last.completedAt.timeIntervalSince(first.completedAt))
        return frames.count >= configuration.segmentTarget.maximumFrames
            || duration >= configuration.segmentTarget.maximumDuration
            || totalBytes >= configuration.segmentTarget.maximumBytes
    }

    private func wouldExceedSegment(_ frames: [StoredSpoolFrame], adding frame: StoredSpoolFrame) -> Bool {
        guard let first = frames.first else { return false }
        let bytes = frames.reduce(frame.byteCount) { $0 + $1.byteCount }
        let duration = max(0, frame.completedAt.timeIntervalSince(first.completedAt))
        return frames.count + 1 > configuration.segmentTarget.maximumFrames
            || duration > configuration.segmentTarget.maximumDuration
            || bytes > configuration.segmentTarget.maximumBytes
    }

    private func attemptSeal(_ key: WindowKey) async -> Bool {
        do {
            try await sealAccumulator(key)
            let deferred = deferredFrames.removeValue(forKey: key) ?? []
            for frame in deferred {
                await accumulate(frame)
            }
            let resolvedIDs = sealFailureIDsByWindow.removeValue(forKey: key) ?? []
            resolve {
                if case let .segmentFailed(jobID, _) = $0 { return resolvedIDs.contains(jobID) }
                return false
            }
            return true
        } catch {
            let failureID = makeID()
            sealFailureIDsByWindow[key, default: []].insert(failureID)
            degrade(.segmentFailed(jobID: failureID, message: String(describing: error)))
            scheduleSealRetry(key)
            return false
        }
    }

    private func scheduleSealRetry(_ key: WindowKey) {
        guard sealRetryScheduled.insert(key).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.retrySealAfterDelay(key)
        }
    }

    private func retrySealAfterDelay(_ key: WindowKey) async {
        sealRetryScheduled.remove(key)
        while maintenanceLease != nil {
            await Task.yield()
        }
        guard accumulators[key]?.isEmpty == false || deferredFrames[key]?.isEmpty == false else { return }
        _ = await attemptSeal(key)
    }

    private func sealAccumulator(_ key: WindowKey) async throws {
        guard let frames = accumulators[key], !frames.isEmpty else { return }
        let first = frames[0]
        let jobID = makeID()
        let assetID = makeID()
        let handle = RecordingSessionHandle(
            sessionID: first.sessionID,
            bundleIdentifier: first.bundleIdentifier,
            processIdentifier: first.processIdentifier,
            generation: first.generation
        )
        let urls = try fileStorage.segmentAssetURLs(handle, assetID)
        let manifest = SegmentJobManifest(
            jobID: jobID,
            assetID: assetID,
            handle: handle,
            windowID: key.windowID,
            partialURL: urls.partial,
            finalURL: urls.final,
            canvasWidth: even(first.pixelWidth),
            canvasHeight: even(first.pixelHeight),
            frames: frames.enumerated().map { index, frame in
                SegmentFrameInput(
                    frameID: frame.id,
                    spoolURL: frame.spoolURL,
                    ptsValue: Int64(index),
                    ptsTimescale: configuration.mediaTimescale
                )
            },
            createdAt: now()
        )
        try await persistence.createSegmentJob(manifest)
        accumulators[key] = nil
        startSegmentWorkerIfNeeded()
    }

    private func even(_ value: Int) -> Int {
        max(2, value + (value % 2))
    }

    private func startSegmentWorkerIfNeeded() {
        guard maintenanceLease == nil, !isSegmentWorkerRunning else { return }
        isSegmentWorkerRunning = true
        Task { await self.runSegmentJobs() }
    }

    private func runSegmentJobs() async {
        defer { isSegmentWorkerRunning = false }
        while maintenanceLease == nil {
            let lease: SegmentJobLease
            do {
                guard let next = try await persistence.leaseSegmentJob(workerID, now(), configuration.leaseDuration) else {
                    if failedJobsBySession.values.contains(where: { !$0.isEmpty }) {
                        scheduleSegmentRetry()
                    }
                    return
                }
                lease = next
            } catch {
                degrade(.recoveryFailed(message: String(describing: error)))
                scheduleSegmentRetry()
                return
            }
            await process(lease)
        }
    }

    private func scheduleSegmentRetry() {
        guard !isSegmentRetryScheduled else { return }
        isSegmentRetryScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.restartSegmentWorkerAfterDelay()
        }
    }

    private func restartSegmentWorkerAfterDelay() async {
        isSegmentRetryScheduled = false
        while isSegmentWorkerRunning {
            await Task.yield()
        }
        startSegmentWorkerIfNeeded()
    }

    private func process(_ lease: SegmentJobLease) async {
        let manifest = lease.manifest
        do {
            let verification: SegmentWriteVerification
            if await fileStorage.fileExists(manifest.finalURL) {
                do {
                    verification = try await segmentWriter.verifyPublished(manifest)
                } catch {
                    // This job is not committed, so a final that fails exact verification is not authoritative.
                    _ = try await fileStorage.removeFilesStrict([manifest.finalURL])
                    throw error
                }
            } else {
                if await fileStorage.fileExists(manifest.partialURL) {
                    _ = try await fileStorage.removeFilesStrict([manifest.partialURL])
                }
                let quality = min(1, max(0, segmentQuality()))
                verification = try await segmentWriter.writeAndVerify(manifest, quality)
                try await fileStorage.publishSegment(manifest.partialURL, manifest.finalURL)
            }
            let publication = SegmentJobCommit(
                jobID: manifest.jobID,
                workerID: lease.workerID,
                assetID: manifest.assetID,
                finalURL: manifest.finalURL,
                byteCount: verification.byteCount,
                frameCount: verification.sampleCount,
                canvasWidth: verification.canvasWidth,
                canvasHeight: verification.canvasHeight
            )
            try await persistence.markSegmentJobPublished(publication)
            let cleanup = try await persistence.commitSegmentJob(publication)
            releaseCommittedSpoolPressure(cleanup)
            failedJobsBySession[manifest.sessionID]?.remove(manifest.jobID)
            if failedJobsBySession[manifest.sessionID]?.isEmpty == true {
                failedJobsBySession[manifest.sessionID] = nil
            }
            resolve {
                if case let .segmentFailed(jobID, _) = $0 { return jobID == manifest.jobID }
                return false
            }
            emit(.segmentCommitted(
                handle: manifest.handle,
                assetID: manifest.assetID,
                frameIDs: manifest.frames.map(\.frameID),
                url: manifest.finalURL
            ))
        } catch {
            failedJobsBySession[manifest.sessionID, default: []].insert(manifest.jobID)
            // A valid published final is preserved for idempotent adoption; invalid finals were removed above.
            let finalByteCount = (try? await fileStorage.fileSize(manifest.finalURL)) ?? 0
            try? await persistence.failSegmentJob(
                manifest.jobID,
                lease.workerID,
                String(describing: error),
                now().addingTimeInterval(1),
                finalByteCount
            )
            degrade(.segmentFailed(jobID: manifest.jobID, message: String(describing: error)))
            scheduleSegmentRetry()
        }
    }

    private func releaseCommittedSpoolPressure(_ urls: [URL]) {
        for url in urls {
            if let byteCount = knownSpoolBytes.removeValue(forKey: url) {
                spoolBytes = max(0, spoolBytes - byteCount)
            }
        }
    }

    private func recoverCommittedSpoolCleanup() async throws {
        for cleanup in try await persistence.pendingSegmentCleanups() {
            _ = try await fileStorage.removeFilesStrict(cleanup.spoolURLs)
            try await persistence.completeSegmentCleanup(cleanup.jobID)
        }
    }

    private func recoverSpoolJournal() async throws {
        var recoveredCount: Int
        repeat {
            let recovery = try await persistence.recoverSpoolFrames(configuration.recoveryBatchSize)
            recoveredCount = recovery.count
            for item in recovery {
                switch item.state {
                case .registered:
                    guard await fileStorage.fileExists(item.registration.spoolURL) else {
                        try await persistence.failSpoolFrame(item.registration.id, "Registered spool file is missing")
                        degrade(.recoveryFailed(message: "Registered spool \(item.registration.id) is missing"))
                        continue
                    }
                    let byteCount = try await fileStorage.fileSize(item.registration.spoolURL)
                    let stored = try await persistence.markSpoolFrameReady(item.registration.id, byteCount)
                    account(stored)
                    await accumulate(stored)
                    emit(.frameCommitted(stored))
                case .ready:
                    if let byteCount = item.byteCount {
                        account(StoredSpoolFrame(registration: item.registration, byteCount: byteCount))
                    }
                case .failed:
                    guard await fileStorage.fileExists(item.registration.spoolURL) else {
                        try await persistence.deleteScreenshots([item.registration.id])
                        continue
                    }
                    let byteCount = try await fileStorage.fileSize(item.registration.spoolURL)
                    let stored = try await persistence.markSpoolFrameReady(item.registration.id, byteCount)
                    account(stored)
                    await accumulate(stored)
                    emit(.frameCommitted(stored))
                }
            }
        } while recoveredCount == configuration.recoveryBatchSize
    }

    private func recoverSegmentJournal() async throws {
        let items = try await persistence.recoverSegmentJobs(now())
        for item in items {
            if await fileStorage.fileExists(item.manifest.finalURL) { continue }
            if await fileStorage.fileExists(item.manifest.partialURL) {
                _ = try await fileStorage.removeFiles([item.manifest.partialURL])
            }
        }
    }

    private func loadPendingFrames() async throws -> Int {
        let frames = try await persistence.pendingSpoolFrames(configuration.recoveryBatchSize)
            .sorted {
                if $0.sessionID != $1.sessionID { return $0.sessionID.uuidString < $1.sessionID.uuidString }
                if $0.windowID != $1.windowID { return $0.windowID.uuidString < $1.windowID.uuidString }
                if $0.cycleSequence != $1.cycleSequence { return $0.cycleSequence < $1.cycleSequence }
                return $0.id.uuidString < $1.id.uuidString
            }
        for frame in frames {
            knownSpoolBytes[frame.spoolURL] = frame.byteCount
            await accumulate(frame)
        }
        return frames.count
    }
}
