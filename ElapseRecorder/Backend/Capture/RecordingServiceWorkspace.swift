import Chronicle
import Foundation

extension RecordingService {
    func beginIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        isBootstrapping = true

        let workspace = dependencies.workspace
        workspaceTask = Task {
            for await event in workspace.events() {
                await self.receiveWorkspaceEvent(event)
            }
        }

        Task { await bootstrap() }
    }

    func bootstrap() async {
        let storage = dependencies.storage
        let storageEvents = await storage.events()
        storageEventTask = Task {
            for await event in storageEvents {
                self.receiveStorageEvent(event)
            }
        }
        let frontmostApplication = await dependencies.workspace.frontmostApplication()
        frontmostBundleIdentifier = frontmostApplication?.bundleIdentifier
        await storage.setCompactionSuspended(shouldSuspendCompaction)
        await storage.recover()

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
            await handleWorkspaceEvent(event)
        }
        reconcileAutomaticSessions()
        attemptAllPendingManualStarts()
        dependencies.logger.log(.info, "Recording service started", [:])
    }

    func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    func emit(_ event: RecordingServiceEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    var sortedRunningApplications: [RunningApplication] {
        runningApplications.values.sorted {
            if $0.displayName == $1.displayName {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func receiveWorkspaceEvent(_ event: WorkspaceEvent) async {
        if isBootstrapping {
            pendingWorkspaceEvents.append(event)
            return
        }
        await handleWorkspaceEvent(event)
    }

    func handleWorkspaceEvent(_ event: WorkspaceEvent) async {
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
                if frontmostBundleIdentifier == application.bundleIdentifier {
                    frontmostBundleIdentifier = nil
                    await synchronizeCompactionSuspension()
                }
                emit(.runningApplicationsChanged(sortedRunningApplications))
            }
            if let sessionID = currentSessionByBundleIdentifier[application.bundleIdentifier],
               runsBySessionID[sessionID]?.handle.processIdentifier == application.processIdentifier
            {
                stopRun(sessionID: sessionID)
            }

        case let .activated(application):
            registerRunningApplication(application)
            frontmostBundleIdentifier = application.bundleIdentifier
            await synchronizeCompactionSuspension()
        }
    }

    func runningApplicationsLoaded(_ applications: [RunningApplication], generation: UInt64) {
        guard generation == refreshGeneration else { return }
        replaceRunningApplications(applications)
        reconcileAutomaticSessions()
        attemptAllPendingManualStarts()
    }

    func replaceRunningApplications(_ applications: [RunningApplication]) {
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

    func permissionRequestCompleted(_ status: CapturePermissionStatus, generation: UInt64) {
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

    func reconcileAutomaticSessions() {
        guard !isBootstrapping, permissionStatus == .authorized else { return }
        for bundleIdentifier in whitelist.keys {
            reconcileAutomaticSession(bundleIdentifier: bundleIdentifier)
        }
    }

    func reconcileAutomaticSession(bundleIdentifier: String) {
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

    func attemptAllPendingManualStarts() {
        for bundleIdentifier in Array(pendingManualStarts) {
            attemptPendingManualStart(bundleIdentifier)
        }
    }

    func attemptPendingManualStart(_ bundleIdentifier: String) {
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

    func hasUnclosedRun(bundleIdentifier: String) -> Bool {
        runsBySessionID.values.contains { $0.handle.bundleIdentifier == bundleIdentifier }
    }
}
