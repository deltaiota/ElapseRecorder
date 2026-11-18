import Chronicle
import Foundation

extension RecordingService {
    func runSchedule(_ schedule: Schedule) async {
        let handle = schedule.handle
        let generation = schedule.generation
        let anchor = schedule.anchor
        let monotonicOrigin = schedule.monotonicOrigin
        let interval = schedule.interval
        let clock = schedule.clock
        if schedule.startImmediately {
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

    func scheduledDeadlineReached(
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
        Task(priority: .background) {
            do {
                let windows = try await screenCapture.windows(application)
                self.windowsLoaded(windows, token: token)
            } catch {
                self.windowsLoadFailed(token: token, message: error.localizedDescription)
            }
        }
    }

    func windowsLoaded(_ windows: [CapturableWindow], token: CycleToken) {
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
        let minimumFrameInterval = max(1, run.config.captureInterval)
        Task(priority: .background) {
            await acquireFrames(jobs, token: token, minimumFrameInterval: minimumFrameInterval)
        }
    }

    func windowsLoadFailed(token: CycleToken, message: String) {
        guard runForActiveCycle(token) != nil else { return }
        emit(.diagnostic(.failure(message)))
        finishCycle(token)
    }

    func acquireFrames(_ jobs: [CaptureJob], token: CycleToken, minimumFrameInterval: TimeInterval) async {
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
                group.addTask(priority: .background) {
                    var jobIndex = workerIndex
                    while jobIndex < jobs.count {
                        let job = jobs[jobIndex]
                        do {
                            try await persistence.upsertWindow(job.monitoredWindow)
                            let requestStartedAt = date.now()
                            let image = try await screenCapture.capture(
                                job.metadata.systemWindowID,
                                minimumFrameInterval
                            )
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

    func storageBackpressured(token: CycleToken, capacity: Int) {
        guard runForActiveCycle(token) != nil else { return }
        pauseForStorageDegradation(.queueFull(capacity: capacity))
    }

    func captureOperationFailed(token: CycleToken, message: String) {
        guard runForActiveCycle(token) != nil else { return }
        emit(.diagnostic(.failure(message)))
    }

    func unavailableRecordCompleted(_ record: CaptureUnavailableRecord, token: CycleToken) {
        guard runForActiveCycle(token) != nil else { return }
        emit(.captureUnavailableRecorded(token.handle, record))
        finishCycle(token)
    }

    func unavailableRecordFailed(token: CycleToken, message: String) {
        guard runForActiveCycle(token) != nil else { return }
        emit(.diagnostic(.failure(message)))
        finishCycle(token)
    }

    func finishCycle(_ token: CycleToken) {
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
}
