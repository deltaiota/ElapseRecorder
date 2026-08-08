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

    private struct CycleToken: Equatable {
        var handle: RecordingSessionHandle
        var sequence: Int64
        var scheduledOffsetNanoseconds: Int64
        var encodingOptions: CaptureEncodingOptions
    }

    private struct CaptureJob {
        var monitoredWindow: MonitoredWindow
        var metadata: CapturedWindowMetadata
    }

    private enum RunPhase: Equatable {
        case opening
        case recording
        case stopping
        case closing
    }

    private struct Run {
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

    private let dependencies: Dependencies
    private var continuations: [UUID: AsyncStream<RecordingServiceEvent>.Continuation] = [:]
    private var hasStarted = false
    private var isBootstrapping = false
    private var permissionStatus: CapturePermissionStatus = .notDetermined
    private var permissionRequestGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var whitelist: [String: WhitelistedAppConfig] = [:]
    private var runningApplications: [String: RunningApplication] = [:]
    private var generationByBundleIdentifier: [String: UInt64] = [:]
    private var currentSessionByBundleIdentifier: [String: UUID] = [:]
    private var runsBySessionID: [UUID: Run] = [:]
    private var userPausedBundleIdentifiers: Set<String> = []
    private var activeStorageDegradation: StorageDegradation?
    private var pendingManualStarts: Set<String> = []
    private var pendingWorkspaceEvents: [WorkspaceEvent] = []
    private var workspaceTask: Task<Void, Never>?
    private var storageEventTask: Task<Void, Never>?
    private var openRetryTasks: [String: Task<Void, Never>] = [:]
    private var openRetryAttempts: [String: Int] = [:]
    private var closeRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var closeRetryAttempts: [UUID: Int] = [:]

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

    private func beginIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        isBootstrapping = true

        let workspace = dependencies.workspace
        workspaceTask = Task {
            for await event in workspace.events() {
                self.receiveWorkspaceEvent(event)
            }
        }

        Task { await bootstrap() }
    }

    private func bootstrap() async {
        let storage = dependencies.storage
        let storageEvents = await storage.events()
        storageEventTask = Task {
            for await event in storageEvents {
                self.receiveStorageEvent(event)
            }
        }
        await dependencies.storage.recover()

        do {
            let count = try await dependencies.persistence.closeOpenSessions(dependencies.date.now())
            if count > 0 {
                emit(.diagnostic(.closedStaleSessions(count: count)))
            }
        } catch {
            emit(.diagnostic(.failure(error.localizedDescription)))
        }

        permissionStatus = await dependencies.permission.status()
        emit(.permissionChanged(permissionStatus))
        let applications = await dependencies.workspace.runningApplications()
        replaceRunningApplications(applications)

        let bufferedEvents = pendingWorkspaceEvents
        pendingWorkspaceEvents.removeAll(keepingCapacity: true)
        isBootstrapping = false
        for event in bufferedEvents {
            handleWorkspaceEvent(event)
        }
        reconcileAutomaticSessions()
        attemptAllPendingManualStarts()
        dependencies.logger.log(.info, "Recording service started", [:])
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: RecordingServiceEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private var sortedRunningApplications: [RunningApplication] {
        runningApplications.values.sorted {
            if $0.displayName == $1.displayName {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func receiveWorkspaceEvent(_ event: WorkspaceEvent) {
        if isBootstrapping {
            pendingWorkspaceEvents.append(event)
            return
        }
        handleWorkspaceEvent(event)
    }

    private func handleWorkspaceEvent(_ event: WorkspaceEvent) {
        emit(.workspaceEvent(event))
        switch event {
        case let .launched(application):
            registerRunningApplication(application)
            reconcileAutomaticSession(bundleIdentifier: application.bundleIdentifier)
            if pendingManualStarts.contains(application.bundleIdentifier) {
                attemptPendingManualStart(application.bundleIdentifier)
            }

        case let .terminated(application):
            if runningApplications[application.bundleIdentifier]?.processIdentifier == application.processIdentifier {
                runningApplications[application.bundleIdentifier] = nil
                emit(.runningApplicationsChanged(sortedRunningApplications))
            }
            if let sessionID = currentSessionByBundleIdentifier[application.bundleIdentifier],
               runsBySessionID[sessionID]?.handle.processIdentifier == application.processIdentifier
            {
                stopRun(sessionID: sessionID)
            }

        case let .activated(application):
            registerRunningApplication(application)
        }
    }

    private func runningApplicationsLoaded(_ applications: [RunningApplication], generation: UInt64) {
        guard generation == refreshGeneration else { return }
        replaceRunningApplications(applications)
        reconcileAutomaticSessions()
        attemptAllPendingManualStarts()
    }

    private func replaceRunningApplications(_ applications: [RunningApplication]) {
        let replacement = Dictionary(
            applications.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        runningApplications = replacement
        emit(.runningApplicationsChanged(sortedRunningApplications))

        for (bundleIdentifier, sessionID) in Array(currentSessionByBundleIdentifier) {
            guard let run = runsBySessionID[sessionID] else { continue }
            if replacement[bundleIdentifier]?.processIdentifier != run.handle.processIdentifier {
                stopRun(sessionID: sessionID)
            }
        }
    }

    func registerRunningApplication(_ application: RunningApplication) {
        if let sessionID = currentSessionByBundleIdentifier[application.bundleIdentifier],
           let run = runsBySessionID[sessionID],
           run.handle.processIdentifier != application.processIdentifier
        {
            stopRun(sessionID: sessionID)
        }
        runningApplications[application.bundleIdentifier] = application
        emit(.runningApplicationsChanged(sortedRunningApplications))
        reconcileAutomaticSession(bundleIdentifier: application.bundleIdentifier)
        if pendingManualStarts.contains(application.bundleIdentifier) {
            attemptPendingManualStart(application.bundleIdentifier)
        }
    }

    private func permissionRequestCompleted(_ status: CapturePermissionStatus, generation: UInt64) {
        guard generation == permissionRequestGeneration else { return }
        permissionStatus = status
        emit(.permissionChanged(status))
        guard status == .authorized else {
            if status == .denied {
                emit(.diagnostic(.permissionRequired))
            }
            return
        }
        reconcileAutomaticSessions()
        attemptAllPendingManualStarts()
    }

    private func reconcileAutomaticSessions() {
        guard !isBootstrapping, permissionStatus == .authorized else { return }
        for bundleIdentifier in whitelist.keys {
            reconcileAutomaticSession(bundleIdentifier: bundleIdentifier)
        }
    }

    private func reconcileAutomaticSession(bundleIdentifier: String) {
        guard activeStorageDegradation == nil,
              permissionStatus == .authorized,
              !userPausedBundleIdentifiers.contains(bundleIdentifier),
              !hasUnclosedRun(bundleIdentifier: bundleIdentifier),
              let config = whitelist[bundleIdentifier],
              config.captureMode == .auto,
              config.isEnabled,
              let application = runningApplications[bundleIdentifier]
        else { return }
        openSession(application: application, config: config)
    }

    private func attemptAllPendingManualStarts() {
        for bundleIdentifier in Array(pendingManualStarts) {
            attemptPendingManualStart(bundleIdentifier)
        }
    }

    private func attemptPendingManualStart(_ bundleIdentifier: String) {
        guard pendingManualStarts.contains(bundleIdentifier),
              permissionStatus == .authorized,
              activeStorageDegradation == nil,
              !userPausedBundleIdentifiers.contains(bundleIdentifier),
              !hasUnclosedRun(bundleIdentifier: bundleIdentifier),
              let config = whitelist[bundleIdentifier]
        else { return }
        guard config.allowsRecordingSession else {
            pendingManualStarts.remove(bundleIdentifier)
            return
        }
        guard let application = runningApplications[bundleIdentifier] else {
            emit(.diagnostic(.appNotRunning(displayName: config.displayName)))
            return
        }
        pendingManualStarts.remove(bundleIdentifier)
        openSession(application: application, config: config)
    }

    private func hasUnclosedRun(bundleIdentifier: String) -> Bool {
        runsBySessionID.values.contains { $0.handle.bundleIdentifier == bundleIdentifier }
    }

    private func openSession(application: RunningApplication, config: WhitelistedAppConfig) {
        guard currentSessionByBundleIdentifier[application.bundleIdentifier] == nil else { return }
        pendingManualStarts.remove(application.bundleIdentifier)
        let generation = (generationByBundleIdentifier[application.bundleIdentifier] ?? 0) &+ 1
        generationByBundleIdentifier[application.bundleIdentifier] = generation
        let session = CaptureSession(
            id: dependencies.ids.uuid(),
            bundleIdentifier: application.bundleIdentifier,
            displayName: config.displayName,
            processIdentifier: application.processIdentifier,
            startedAt: dependencies.date.now()
        )
        let handle = RecordingSessionHandle(
            sessionID: session.id,
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            generation: generation
        )
        var run = Run(
            handle: handle,
            application: application,
            config: config,
            session: session,
            monotonicOrigin: dependencies.clock.now()
        )
        run.pauseReason = activeStorageDegradation.map(RecordingPauseReason.storageUnavailable)
        runsBySessionID[session.id] = run
        currentSessionByBundleIdentifier[application.bundleIdentifier] = session.id

        dependencies.logger.log(
            .info,
            "Opening recording session",
            ["bundle": .string(application.bundleIdentifier), "session": .string(session.id.uuidString)]
        )
        let persistence = dependencies.persistence
        Task {
            do {
                try await persistence.openSession(session)
                self.sessionOpenCompleted(handle)
            } catch {
                self.sessionOpenFailed(handle, message: error.localizedDescription)
            }
        }
    }

    private func sessionOpenCompleted(_ handle: RecordingSessionHandle) {
        guard var run = correlatedRun(handle) else {
            closeOrphanedSession(handle)
            return
        }
        if run.phase == .stopping {
            runsBySessionID[handle.sessionID] = run
            finalizeStopIfDrained(sessionID: handle.sessionID)
            return
        }
        guard run.phase == .opening else { return }
        cancelOpenRetry(handle.bundleIdentifier)
        run.phase = .recording
        runsBySessionID[handle.sessionID] = run
        emit(.sessionOpened(run.snapshot))
        if run.pauseReason == nil {
            reanchorSchedule(for: handle.sessionID, startImmediately: true)
        }
    }

    private func sessionOpenFailed(_ handle: RecordingSessionHandle, message: String) {
        guard let run = correlatedRun(handle) else { return }
        run.schedulerTask?.cancel()
        runsBySessionID[handle.sessionID] = nil
        if currentSessionByBundleIdentifier[handle.bundleIdentifier] == handle.sessionID {
            currentSessionByBundleIdentifier[handle.bundleIdentifier] = nil
        }
        emit(.diagnostic(.failure(message)))
        if run.config.captureMode == .auto, run.config.isEnabled {
            scheduleOpenRetry(handle.bundleIdentifier)
        }
    }

    private func scheduleOpenRetry(_ bundleIdentifier: String) {
        guard openRetryTasks[bundleIdentifier] == nil else { return }
        let attempt = (openRetryAttempts[bundleIdentifier] ?? 0) + 1
        openRetryAttempts[bundleIdentifier] = attempt
        let delay = retryDelay(attempt: attempt)
        let clock = dependencies.clock
        openRetryTasks[bundleIdentifier] = Task { [weak self] in
            do {
                try await clock.sleep(delay)
            } catch {
                return
            }
            await self?.performOpenRetry(bundleIdentifier)
        }
    }

    private func performOpenRetry(_ bundleIdentifier: String) {
        openRetryTasks[bundleIdentifier] = nil
        reconcileAutomaticSession(bundleIdentifier: bundleIdentifier)
    }

    private func cancelOpenRetry(_ bundleIdentifier: String) {
        openRetryTasks.removeValue(forKey: bundleIdentifier)?.cancel()
        openRetryAttempts[bundleIdentifier] = nil
    }

    private func closeOrphanedSession(_ handle: RecordingSessionHandle) {
        let persistence = dependencies.persistence
        let endedAt = dependencies.date.now()
        Task {
            do {
                try await persistence.closeSession(handle.sessionID, endedAt)
            } catch {
                self.emitDiagnostic(.failure(error.localizedDescription))
            }
        }
    }

    private func stopRun(sessionID: UUID) {
        guard var run = runsBySessionID[sessionID], run.phase != .closing, run.phase != .stopping else { return }
        let wasOpening = run.phase == .opening
        if currentSessionByBundleIdentifier[run.handle.bundleIdentifier] == sessionID {
            currentSessionByBundleIdentifier[run.handle.bundleIdentifier] = nil
        }
        run.phase = .stopping
        run.scheduleGeneration &+= 1
        run.schedulerTask?.cancel()
        run.schedulerTask = nil
        runsBySessionID[sessionID] = run
        if !wasOpening {
            finalizeStopIfDrained(sessionID: sessionID)
        }
    }

    private func finalizeStopIfDrained(sessionID: UUID) {
        guard var run = runsBySessionID[sessionID],
              run.phase == .stopping,
              run.activeCycleSequences.isEmpty
        else { return }
        run.phase = .closing
        runsBySessionID[sessionID] = run
        let storage = dependencies.storage
        let persistence = dependencies.persistence
        let handle = run.handle
        let endedAt = dependencies.date.now()
        Task {
            do {
                try await storage.flushSession(handle)
                try await persistence.closeSession(handle.sessionID, endedAt)
                self.sessionCloseCompleted(handle, endedAt: endedAt)
            } catch {
                self.sessionCloseFailed(handle, message: error.localizedDescription)
            }
        }
    }

    private func sessionCloseCompleted(_ handle: RecordingSessionHandle, endedAt: Date) {
        guard correlatedRun(handle)?.phase == .closing else { return }
        closeRetryTasks.removeValue(forKey: handle.sessionID)?.cancel()
        closeRetryAttempts[handle.sessionID] = nil
        runsBySessionID[handle.sessionID] = nil
        emit(.sessionClosed(handle, endedAt: endedAt))
        dependencies.logger.log(
            .info,
            "Recording session closed",
            ["bundle": .string(handle.bundleIdentifier), "session": .string(handle.sessionID.uuidString)]
        )
        reconcileAutomaticSession(bundleIdentifier: handle.bundleIdentifier)
        if pendingManualStarts.contains(handle.bundleIdentifier) {
            attemptPendingManualStart(handle.bundleIdentifier)
        }
    }

    private func sessionCloseFailed(_ handle: RecordingSessionHandle, message: String) {
        guard var run = correlatedRun(handle), run.phase == .closing else { return }
        run.phase = .stopping
        runsBySessionID[handle.sessionID] = run
        emit(.diagnostic(.failure(message)))
        scheduleCloseRetry(handle)
    }

    private func scheduleCloseRetry(_ handle: RecordingSessionHandle) {
        guard closeRetryTasks[handle.sessionID] == nil else { return }
        let attempt = (closeRetryAttempts[handle.sessionID] ?? 0) + 1
        closeRetryAttempts[handle.sessionID] = attempt
        let delay = retryDelay(attempt: attempt)
        let clock = dependencies.clock
        closeRetryTasks[handle.sessionID] = Task { [weak self] in
            do {
                try await clock.sleep(delay)
            } catch {
                return
            }
            await self?.performCloseRetry(handle)
        }
    }

    private func performCloseRetry(_ handle: RecordingSessionHandle) {
        closeRetryTasks[handle.sessionID] = nil
        guard correlatedRun(handle)?.phase == .stopping else { return }
        finalizeStopIfDrained(sessionID: handle.sessionID)
    }

    private func retryDelay(attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(max(0, attempt - 1), 4)))
    }

    private func reanchorSchedule(for sessionID: UUID, startImmediately: Bool) {
        guard var run = runsBySessionID[sessionID], run.phase == .recording, run.pauseReason == nil else { return }
        run.scheduleGeneration &+= 1
        run.schedulerTask?.cancel()
        let scheduleGeneration = run.scheduleGeneration
        let handle = run.handle
        let interval = run.config.sanitizedInterval
        let anchor = dependencies.clock.now()
        let monotonicOrigin = run.monotonicOrigin
        let clock = dependencies.clock
        run.schedulerTask = Task {
            await self.runSchedule(
                handle: handle,
                generation: scheduleGeneration,
                anchor: anchor,
                monotonicOrigin: monotonicOrigin,
                interval: interval,
                startImmediately: startImmediately,
                clock: clock
            )
        }
        runsBySessionID[sessionID] = run
    }

    private func runSchedule(
        handle: RecordingSessionHandle,
        generation: UInt64,
        anchor: Duration,
        monotonicOrigin: Duration,
        interval: Duration,
        startImmediately: Bool,
        clock: RecordingServiceClock
    ) async {
        if startImmediately {
            scheduledDeadlineReached(
                handle: handle,
                scheduleGeneration: generation,
                scheduledOffset: anchor - monotonicOrigin
            )
        }

        var deadline = anchor + interval
        while !Task.isCancelled {
            do {
                try await clock.sleep(until: deadline)
            } catch is CancellationError {
                return
            } catch {
                emit(.diagnostic(.failure(error.localizedDescription)))
                return
            }
            guard !Task.isCancelled else { return }
            scheduledDeadlineReached(
                handle: handle,
                scheduleGeneration: generation,
                scheduledOffset: deadline - monotonicOrigin
            )

            let now = clock.now()
            let nextNominalDeadline = deadline + interval
            deadline = nextNominalDeadline <= now ? now + interval : nextNominalDeadline
        }
    }

    private func scheduledDeadlineReached(
        handle: RecordingSessionHandle,
        scheduleGeneration: UInt64,
        scheduledOffset: Duration
    ) {
        guard var run = correlatedRun(handle),
              run.phase == .recording,
              run.scheduleGeneration == scheduleGeneration,
              run.pauseReason == nil
        else { return }

        if !run.activeCycleSequences.isEmpty {
            emit(
                .schedulerDeadlineMissed(
                    handle,
                    cycleSequence: run.nextCycleSequence,
                    scheduledOffsetNanoseconds: scheduledOffset.saturatedNanoseconds
                )
            )
            dependencies.logger.log(
                .info,
                "Skipped recording deadline while capture cycle was still active",
                [
                    "bundle": .string(handle.bundleIdentifier),
                    "session": .string(handle.sessionID.uuidString),
                    "cycle": .string(String(run.nextCycleSequence)),
                ]
            )
            return
        }

        run.nextCycleSequence &+= 1
        let sequence = run.nextCycleSequence
        run.activeCycleSequences.insert(sequence)
        runsBySessionID[handle.sessionID] = run
        emit(.sessionUpdated(run.snapshot))

        let token = CycleToken(
            handle: handle,
            sequence: sequence,
            scheduledOffsetNanoseconds: scheduledOffset.saturatedNanoseconds,
            encodingOptions: dependencies.preferences.encodingOptions()
        )
        let screenCapture = dependencies.screenCapture
        let application = run.application
        Task {
            do {
                let windows = try await screenCapture.windows(application)
                self.windowsLoaded(windows, token: token)
            } catch {
                self.windowsLoadFailed(token: token, message: error.localizedDescription)
            }
        }
    }

    private func windowsLoaded(_ windows: [CapturableWindow], token: CycleToken) {
        guard var run = runForActiveCycle(token) else { return }
        let observedAt = dependencies.date.now()
        let capturableWindows = CapturableWindow.capturableWindows(from: windows)
        guard !capturableWindows.isEmpty else {
            guard !run.windowsBySystemID.isEmpty else {
                runsBySessionID[token.handle.sessionID] = run
                finishCycle(token)
                return
            }

            run.captureUnavailableReason = .windowMinimized
            let recordID = run.unavailableRecordID ?? dependencies.ids.uuid()
            let startedAt = run.unavailableStartedAt ?? observedAt
            run.unavailableRecordID = recordID
            run.unavailableStartedAt = startedAt
            runsBySessionID[token.handle.sessionID] = run
            emit(.sessionUpdated(run.snapshot))

            let record = CaptureUnavailableRecord(
                id: recordID,
                sessionID: token.handle.sessionID,
                startedAt: startedAt,
                endedAt: observedAt,
                reason: .windowMinimized
            )
            let persistence = dependencies.persistence
            Task {
                do {
                    try await persistence.recordCaptureUnavailable(record)
                    self.unavailableRecordCompleted(record, token: token)
                } catch {
                    self.unavailableRecordFailed(token: token, message: error.localizedDescription)
                }
            }
            return
        }

        run.captureUnavailableReason = nil
        run.unavailableRecordID = nil
        run.unavailableStartedAt = nil
        var jobs: [CaptureJob] = []
        jobs.reserveCapacity(capturableWindows.count)

        for window in capturableWindows {
            let title = normalizedWindowTitle(window.title)
            let monitoredWindow: MonitoredWindow
            if var existing = run.windowsBySystemID[window.systemWindowID] {
                existing.lastSeenAt = observedAt
                if existing.titleHistory.last?.title != title {
                    existing.titleHistory.append(
                        WindowTitleObservation(id: dependencies.ids.uuid(), title: title, observedAt: observedAt)
                    )
                }
                monitoredWindow = existing
            } else {
                monitoredWindow = MonitoredWindow(
                    id: dependencies.ids.uuid(),
                    sessionID: token.handle.sessionID,
                    systemWindowID: window.systemWindowID,
                    displayNumber: run.nextWindowNumber,
                    label: title,
                    firstSeenAt: observedAt,
                    lastSeenAt: observedAt,
                    titleHistory: [
                        WindowTitleObservation(id: dependencies.ids.uuid(), title: title, observedAt: observedAt),
                    ]
                )
                run.nextWindowNumber += 1
            }
            run.windowsBySystemID[window.systemWindowID] = monitoredWindow
            jobs.append(
                CaptureJob(
                    monitoredWindow: monitoredWindow,
                    metadata: CapturedWindowMetadata(
                        windowID: monitoredWindow.id,
                        systemWindowID: monitoredWindow.systemWindowID,
                        displayNumber: monitoredWindow.displayNumber,
                        title: monitoredWindow.currentTitle
                    )
                )
            )
        }

        runsBySessionID[token.handle.sessionID] = run
        emit(.sessionUpdated(run.snapshot))
        Task { await acquireFrames(jobs, token: token) }
    }

    private func windowsLoadFailed(token: CycleToken, message: String) {
        guard runForActiveCycle(token) != nil else { return }
        emit(.diagnostic(.failure(message)))
        finishCycle(token)
    }

    private func acquireFrames(_ jobs: [CaptureJob], token: CycleToken) async {
        let maximumConcurrency = dependencies.maximumConcurrentFrameAcquisitions
        let screenCapture = dependencies.screenCapture
        let persistence = dependencies.persistence
        let storage = dependencies.storage
        let date = dependencies.date
        let ids = dependencies.ids
        let perceptualHash = dependencies.perceptualHash

        let workerCount = min(maximumConcurrency, jobs.count)
        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0 ..< workerCount {
                group.addTask {
                    var jobIndex = workerIndex
                    while jobIndex < jobs.count {
                        let job = jobs[jobIndex]
                        do {
                            try await persistence.upsertWindow(job.monitoredWindow)
                            let requestStartedAt = date.now()
                            let image = try await screenCapture.capture(job.metadata.systemWindowID)
                            let completedAt = date.now()
                            let envelope = CapturedFrameEnvelope(
                                id: ids.uuid(),
                                handle: token.handle,
                                cycleSequence: token.sequence,
                                scheduledOffsetNanoseconds: token.scheduledOffsetNanoseconds,
                                requestStartedAt: requestStartedAt,
                                completedAt: completedAt,
                                window: job.metadata,
                                image: ImmutableCapturedImage(image),
                                encodingOptions: token.encodingOptions,
                                perceptualHash: perceptualHash.hash(image)
                            )
                            let enqueueResult = await storage.enqueue(envelope)
                            if case let .backpressured(capacity) = enqueueResult {
                                await self.storageBackpressured(token: token, capacity: capacity)
                            }
                        } catch {
                            await self.captureOperationFailed(token: token, message: error.localizedDescription)
                        }
                        jobIndex += workerCount
                    }
                }
            }
            await group.waitForAll()
        }
        finishCycle(token)
    }

    private func storageBackpressured(token: CycleToken, capacity: Int) {
        guard runForActiveCycle(token) != nil else { return }
        pauseForStorageDegradation(.queueFull(capacity: capacity))
    }

    private func captureOperationFailed(token: CycleToken, message: String) {
        guard runForActiveCycle(token) != nil else { return }
        emit(.diagnostic(.failure(message)))
    }

    private func unavailableRecordCompleted(_ record: CaptureUnavailableRecord, token: CycleToken) {
        guard runForActiveCycle(token) != nil else { return }
        emit(.captureUnavailableRecorded(token.handle, record))
        finishCycle(token)
    }

    private func unavailableRecordFailed(token: CycleToken, message: String) {
        guard runForActiveCycle(token) != nil else { return }
        emit(.diagnostic(.failure(message)))
        finishCycle(token)
    }

    private func finishCycle(_ token: CycleToken) {
        guard var run = correlatedRun(token.handle),
              run.activeCycleSequences.remove(token.sequence) != nil
        else { return }
        runsBySessionID[token.handle.sessionID] = run
        if run.phase == .recording {
            emit(.sessionUpdated(run.snapshot))
        } else if run.phase == .stopping {
            finalizeStopIfDrained(sessionID: token.handle.sessionID)
        }
    }

    private func receiveStorageEvent(_ event: StorageCoordinatorEvent) {
        switch event {
        case let .frameCommitted(frame):
            let handle = RecordingSessionHandle(
                sessionID: frame.sessionID,
                bundleIdentifier: frame.bundleIdentifier,
                processIdentifier: frame.processIdentifier,
                generation: frame.generation
            )
            let record = ScreenshotRecord(
                id: frame.id,
                windowID: frame.windowID,
                sessionID: frame.sessionID,
                capturedAt: frame.completedAt,
                fileURL: frame.spoolURL,
                fileSizeBytes: frame.byteCount,
                pixelWidth: frame.pixelWidth,
                pixelHeight: frame.pixelHeight,
                perceptualHash: frame.perceptualHash
            )
            emit(.frameCommitted(handle, record))

        case let .segmentCommitted(handle, assetID, frameIDs, url):
            emit(.segmentCommitted(handle: handle, assetID: assetID, frameIDs: frameIDs, url: url))

        case let .storageDegraded(degradation):
            pauseForStorageDegradation(degradation)

        case .storageResumed:
            resumeAfterStorageRecovery()
        }
    }

    private func pauseForStorageDegradation(_ degradation: StorageDegradation) {
        guard activeStorageDegradation != degradation else { return }
        activeStorageDegradation = degradation
        for sessionID in Array(runsBySessionID.keys) {
            guard var run = runsBySessionID[sessionID], run.phase == .opening || run.phase == .recording else {
                continue
            }
            run.pauseReason = .storageUnavailable(degradation)
            run.scheduleGeneration &+= 1
            run.schedulerTask?.cancel()
            run.schedulerTask = nil
            runsBySessionID[sessionID] = run
            if run.phase == .recording {
                emit(.sessionUpdated(run.snapshot))
            }
        }
        emit(.storageDegraded(degradation))
    }

    private func resumeAfterStorageRecovery() {
        guard activeStorageDegradation != nil else { return }
        activeStorageDegradation = nil
        let sessionIDs = Array(runsBySessionID.keys)
        for sessionID in sessionIDs {
            guard var run = runsBySessionID[sessionID],
                  run.phase == .opening || run.phase == .recording || run.phase == .stopping
            else {
                continue
            }
            run.pauseReason = userPausedBundleIdentifiers.contains(run.handle.bundleIdentifier) ? .user : nil
            runsBySessionID[sessionID] = run
            if run.phase == .recording {
                emit(.sessionUpdated(run.snapshot))
                if run.pauseReason == nil {
                    reanchorSchedule(for: sessionID, startImmediately: false)
                }
            } else if run.phase == .stopping {
                finalizeStopIfDrained(sessionID: sessionID)
            }
        }
        emit(.storageResumed)
        reconcileAutomaticSessions()
        attemptAllPendingManualStarts()
    }

    private func correlatedRun(_ handle: RecordingSessionHandle) -> Run? {
        guard let run = runsBySessionID[handle.sessionID], run.handle == handle else { return nil }
        return run
    }

    private func runForActiveCycle(_ token: CycleToken) -> Run? {
        guard let run = correlatedRun(token.handle),
              run.activeCycleSequences.contains(token.sequence)
        else { return nil }
        return run
    }

    private func emitDiagnostic(_ diagnostic: CaptureDiagnostic) {
        emit(.diagnostic(diagnostic))
    }

    private func normalizedWindowTitle(_ raw: String?) -> String? {
        guard let title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return title
    }
}

private nonisolated extension WhitelistedAppConfig {
    var allowsRecordingSession: Bool {
        captureMode == .manual || isEnabled
    }
}

private nonisolated extension Duration {
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
