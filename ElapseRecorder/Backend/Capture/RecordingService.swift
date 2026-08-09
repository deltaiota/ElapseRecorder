import Chronicle
import Foundation

nonisolated enum RecordingPauseReason: Equatable {
    case user
    case storageUnavailable(StorageDegradation)
}

nonisolated struct RecordingSessionSnapshot: Equatable {
    var handle: RecordingSessionHandle
    var application: RunningApplication
    var config: WhitelistedAppConfig
    var session: CaptureSession
    var nextWindowNumber: Int
    var windowsBySystemID: [Int: MonitoredWindow]
    var isCaptureInFlight: Bool
    var captureUnavailableReason: CaptureUnavailableReason?
    var pauseReason: RecordingPauseReason?
}

nonisolated enum RecordingServiceEvent: Equatable {
    case permissionChanged(CapturePermissionStatus)
    case runningApplicationsChanged([RunningApplication])
    case workspaceEvent(WorkspaceEvent)
    case sessionOpened(RecordingSessionSnapshot)
    case sessionUpdated(RecordingSessionSnapshot)
    case sessionClosed(RecordingSessionHandle, endedAt: Date)
    case frameCommitted(RecordingSessionHandle, ScreenshotRecord)
    case segmentCommitted(handle: RecordingSessionHandle, assetID: UUID, frameIDs: [UUID], url: URL)
    case captureUnavailableRecorded(RecordingSessionHandle, CaptureUnavailableRecord)
    case diagnostic(CaptureDiagnostic)
    case storageDegraded(StorageDegradation)
    case storageResumed
    case schedulerDeadlineMissed(RecordingSessionHandle, cycleSequence: Int64, scheduledOffsetNanoseconds: Int64)
}

nonisolated struct RecordingServiceClock {
    var now: @Sendable () -> Duration
    var sleep: @Sendable (_ duration: Duration) async throws -> Void

    func sleep(until deadline: Duration) async throws {
        let remaining = deadline - now()
        if remaining > .zero {
            try await sleep(remaining)
        }
    }

    static func continuous() -> Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(
            now: { origin.duration(to: clock.now) },
            sleep: { try await clock.sleep(for: $0) }
        )
    }
}

actor RecordingService {
    struct Dependencies {
        var workspace: WorkspaceClient
        var permission: CapturePermissionClient
        var screenCapture: ScreenCaptureClient
        var persistence: PersistenceClient
        var storage: StorageCoordinatorClient
        var date: DateClient
        var ids: IDGeneratorClient
        var perceptualHash: PerceptualHashClient
        var preferences: CapturePreferencesClient
        var logger: LoggingClient
        var clock: RecordingServiceClock
        var maximumConcurrentFrameAcquisitions: Int

        init(
            workspace: WorkspaceClient,
            permission: CapturePermissionClient,
            screenCapture: ScreenCaptureClient,
            persistence: PersistenceClient,
            storage: StorageCoordinatorClient,
            date: DateClient,
            ids: IDGeneratorClient,
            perceptualHash: PerceptualHashClient,
            preferences: CapturePreferencesClient,
            logger: LoggingClient,
            clock: RecordingServiceClock = .continuous(),
            maximumConcurrentFrameAcquisitions: Int = 3
        ) {
            self.workspace = workspace
            self.permission = permission
            self.screenCapture = screenCapture
            self.persistence = persistence
            self.storage = storage
            self.date = date
            self.ids = ids
            self.perceptualHash = perceptualHash
            self.preferences = preferences
            self.logger = logger
            self.clock = clock
            self.maximumConcurrentFrameAcquisitions = max(1, maximumConcurrentFrameAcquisitions)
        }
    }

    struct CycleToken: Equatable {
        var handle: RecordingSessionHandle
        var sequence: Int64
        var scheduledOffsetNanoseconds: Int64
        var encodingOptions: CaptureEncodingOptions
    }

    struct Schedule {
        var handle: RecordingSessionHandle
        var generation: UInt64
        var anchor: Duration
        var monotonicOrigin: Duration
        var interval: Duration
        var startImmediately: Bool
        var clock: RecordingServiceClock
    }

    struct CaptureJob {
        var monitoredWindow: MonitoredWindow
        var metadata: CapturedWindowMetadata
    }

    enum RunPhase: Equatable {
        case opening
        case recording
        case stopping
        case closing
    }

    struct Run {
        var handle: RecordingSessionHandle
        var application: RunningApplication
        var config: WhitelistedAppConfig
        var session: CaptureSession
        var monotonicOrigin: Duration
        var phase: RunPhase = .opening
        var nextWindowNumber = 1
        var windowsBySystemID: [Int: MonitoredWindow] = [:]
        var captureUnavailableReason: CaptureUnavailableReason?
        var pauseReason: RecordingPauseReason?
        var unavailableRecordID: UUID?
        var unavailableStartedAt: Date?
        var nextCycleSequence: Int64 = 0
        var activeCycleSequences: Set<Int64> = []
        var scheduleGeneration: UInt64 = 0
        var schedulerTask: Task<Void, Never>?

        var snapshot: RecordingSessionSnapshot {
            RecordingSessionSnapshot(
                handle: handle,
                application: application,
                config: config,
                session: session,
                nextWindowNumber: nextWindowNumber,
                windowsBySystemID: windowsBySystemID,
                isCaptureInFlight: !activeCycleSequences.isEmpty,
                captureUnavailableReason: captureUnavailableReason,
                pauseReason: pauseReason
            )
        }
    }

    let dependencies: Dependencies
    var continuations: [UUID: AsyncStream<RecordingServiceEvent>.Continuation] = [:]
    var hasStarted = false
    var isBootstrapping = false
    var permissionStatus: CapturePermissionStatus = .notDetermined
    var permissionRequestGeneration: UInt64 = 0
    var refreshGeneration: UInt64 = 0
    var whitelist: [String: WhitelistedAppConfig] = [:]
    var runningApplications: [String: RunningApplication] = [:]
    var generationByBundleIdentifier: [String: UInt64] = [:]
    var currentSessionByBundleIdentifier: [String: UUID] = [:]
    var runsBySessionID: [UUID: Run] = [:]
    var userPausedBundleIdentifiers: Set<String> = []
    var activeStorageDegradation: StorageDegradation?
    var pendingManualStarts: Set<String> = []
    var pendingWorkspaceEvents: [WorkspaceEvent] = []
    var workspaceTask: Task<Void, Never>?
    var storageEventTask: Task<Void, Never>?
    var openRetryTasks: [String: Task<Void, Never>] = [:]
    var openRetryAttempts: [String: Int] = [:]
    var closeRetryTasks: [UUID: Task<Void, Never>] = [:]
    var closeRetryAttempts: [UUID: Int] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    deinit {
        workspaceTask?.cancel()
        storageEventTask?.cancel()
        for run in runsBySessionID.values {
            run.schedulerTask?.cancel()
        }
        for task in openRetryTasks.values {
            task.cancel()
        }
        for task in closeRetryTasks.values {
            task.cancel()
        }
    }

    func start() -> AsyncStream<RecordingServiceEvent> {
        let subscriberID = dependencies.ids.uuid()
        let (stream, continuation) = AsyncStream<RecordingServiceEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeContinuation(subscriberID) }
        }
        continuations[subscriberID] = continuation

        continuation.yield(.permissionChanged(permissionStatus))
        continuation.yield(.runningApplicationsChanged(sortedRunningApplications))
        for run in runsBySessionID.values where run.phase == .recording {
            continuation.yield(.sessionOpened(run.snapshot))
        }

        beginIfNeeded()
        return stream
    }

    func applyWhitelist(_ configs: [WhitelistedAppConfig]) {
        whitelist = Dictionary(
            configs.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for bundleIdentifier in openRetryTasks.keys where whitelist[bundleIdentifier]?.captureMode != .auto
            || whitelist[bundleIdentifier]?.isEnabled != true
        {
            cancelOpenRetry(bundleIdentifier)
        }
        pendingManualStarts.formIntersection(whitelist.keys)

        for (bundleIdentifier, sessionID) in Array(currentSessionByBundleIdentifier) {
            guard var run = runsBySessionID[sessionID] else { continue }
            guard let config = whitelist[bundleIdentifier], config.allowsRecordingSession else {
                stopRun(sessionID: sessionID)
                continue
            }

            let intervalChanged = config.sanitizedInterval != run.config.sanitizedInterval
            guard config != run.config else { continue }
            run.config = config
            runsBySessionID[sessionID] = run
            if run.phase == .recording {
                emit(.sessionUpdated(run.snapshot))
                if intervalChanged, run.pauseReason == nil {
                    reanchorSchedule(for: sessionID, startImmediately: false)
                }
            }
        }
        userPausedBundleIdentifiers.formIntersection(whitelist.keys)

        reconcileAutomaticSessions()
    }

    func startCapture(bundleIdentifier: String) {
        let removedUserPause = userPausedBundleIdentifiers.remove(bundleIdentifier) != nil
        if removedUserPause,
           let sessionID = currentSessionByBundleIdentifier[bundleIdentifier],
           var run = runsBySessionID[sessionID]
        {
            run.pauseReason = activeStorageDegradation.map(RecordingPauseReason.storageUnavailable)
            runsBySessionID[sessionID] = run
            emit(.sessionUpdated(run.snapshot))
            if run.phase == .recording, run.pauseReason == nil {
                reanchorSchedule(for: sessionID, startImmediately: false)
            }
            return
        }

        pendingManualStarts.insert(bundleIdentifier)
        guard !isBootstrapping else { return }
        guard permissionStatus == .authorized else {
            requestPermission()
            return
        }
        attemptPendingManualStart(bundleIdentifier)
    }

    func stopCapture(bundleIdentifier: String) {
        pendingManualStarts.remove(bundleIdentifier)
        cancelOpenRetry(bundleIdentifier)
        if whitelist[bundleIdentifier]?.captureMode == .auto {
            userPausedBundleIdentifiers.insert(bundleIdentifier)
        }
        guard let sessionID = currentSessionByBundleIdentifier[bundleIdentifier] else { return }
        stopRun(sessionID: sessionID)
    }

    func pauseCapture(bundleIdentifier: String) {
        guard userPausedBundleIdentifiers.insert(bundleIdentifier).inserted,
              let sessionID = currentSessionByBundleIdentifier[bundleIdentifier],
              var run = runsBySessionID[sessionID]
        else { return }
        run.pauseReason = activeStorageDegradation.map(RecordingPauseReason.storageUnavailable) ?? .user
        run.scheduleGeneration &+= 1
        run.schedulerTask?.cancel()
        run.schedulerTask = nil
        runsBySessionID[sessionID] = run
        emit(.sessionUpdated(run.snapshot))
    }

    func resumeCapture(bundleIdentifier: String) {
        guard userPausedBundleIdentifiers.remove(bundleIdentifier) != nil else { return }
        if let sessionID = currentSessionByBundleIdentifier[bundleIdentifier],
           var run = runsBySessionID[sessionID]
        {
            run.pauseReason = activeStorageDegradation.map(RecordingPauseReason.storageUnavailable)
            runsBySessionID[sessionID] = run
            emit(.sessionUpdated(run.snapshot))
            if run.phase == .recording, run.pauseReason == nil {
                reanchorSchedule(for: sessionID, startImmediately: false)
            }
        } else if activeStorageDegradation == nil {
            reconcileAutomaticSession(bundleIdentifier: bundleIdentifier)
        }
    }

    func requestPermission() {
        permissionRequestGeneration &+= 1
        let generation = permissionRequestGeneration
        let permission = dependencies.permission
        Task {
            let status = await permission.request()
            self.permissionRequestCompleted(status, generation: generation)
        }
    }

    func refreshRunningApplications() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let workspace = dependencies.workspace
        Task {
            let applications = await workspace.runningApplications()
            self.runningApplicationsLoaded(applications, generation: generation)
        }
    }
}

nonisolated extension WhitelistedAppConfig {
    var allowsRecordingSession: Bool {
        captureMode == .manual || isEnabled
    }
}

nonisolated extension Duration {
    var saturatedNanoseconds: Int64 {
        let components = self.components
        let (secondsInNanoseconds, secondsOverflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if secondsOverflow {
            return components.seconds >= 0 ? .max : .min
        }
        let subsecondNanoseconds = components.attoseconds / 1_000_000_000
        let (result, additionOverflow) = secondsInNanoseconds.addingReportingOverflow(subsecondNanoseconds)
        if additionOverflow {
            return components.seconds >= 0 ? .max : .min
        }
        return result
    }
}
