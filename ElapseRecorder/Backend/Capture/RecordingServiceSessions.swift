import Chronicle
import Foundation

extension RecordingService {
    func openSession(application: RunningApplication, config: WhitelistedAppConfig) {
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

    func sessionOpenCompleted(_ handle: RecordingSessionHandle) {
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

    func sessionOpenFailed(_ handle: RecordingSessionHandle, message: String) {
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

    func scheduleOpenRetry(_ bundleIdentifier: String) {
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

    func performOpenRetry(_ bundleIdentifier: String) {
        openRetryTasks[bundleIdentifier] = nil
        reconcileAutomaticSession(bundleIdentifier: bundleIdentifier)
    }

    func cancelOpenRetry(_ bundleIdentifier: String) {
        openRetryTasks.removeValue(forKey: bundleIdentifier)?.cancel()
        openRetryAttempts[bundleIdentifier] = nil
    }

    func closeOrphanedSession(_ handle: RecordingSessionHandle) {
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

    func stopRun(sessionID: UUID) {
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

    func finalizeStopIfDrained(sessionID: UUID) {
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

    func sessionCloseCompleted(_ handle: RecordingSessionHandle, endedAt: Date) {
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

    func sessionCloseFailed(_ handle: RecordingSessionHandle, message: String) {
        guard var run = correlatedRun(handle), run.phase == .closing else { return }
        run.phase = .stopping
        runsBySessionID[handle.sessionID] = run
        emit(.diagnostic(.failure(message)))
        scheduleCloseRetry(handle)
    }

    func scheduleCloseRetry(_ handle: RecordingSessionHandle) {
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

    func performCloseRetry(_ handle: RecordingSessionHandle) {
        closeRetryTasks[handle.sessionID] = nil
        guard correlatedRun(handle)?.phase == .stopping else { return }
        finalizeStopIfDrained(sessionID: handle.sessionID)
    }

    func retryDelay(attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(max(0, attempt - 1), 4)))
    }

    func reanchorSchedule(for sessionID: UUID, startImmediately: Bool) {
        guard var run = runsBySessionID[sessionID], run.phase == .recording, run.pauseReason == nil else { return }
        run.scheduleGeneration &+= 1
        run.schedulerTask?.cancel()
        let schedule = Schedule(
            handle: run.handle,
            generation: run.scheduleGeneration,
            anchor: dependencies.clock.now(),
            monotonicOrigin: run.monotonicOrigin,
            interval: run.config.sanitizedInterval,
            startImmediately: startImmediately,
            clock: dependencies.clock
        )
        run.schedulerTask = Task { await self.runSchedule(schedule) }
        runsBySessionID[sessionID] = run
    }
}
