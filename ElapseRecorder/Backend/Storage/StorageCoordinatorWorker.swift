import ComposableArchitecture
import CoreGraphics
import Foundation

extension StorageCoordinator {
    func setCompactionSuspended(_ suspended: Bool) {
        guard isCompactionSuspended != suspended else { return }
        isCompactionSuspended = suspended
        if suspended {
            restartSegmentWorkerWhenStopped = false
            segmentWorkerTask?.cancel()
        } else if isSegmentWorkerRunning {
            restartSegmentWorkerWhenStopped = segmentWorkerTask?.isCancelled == true
        } else {
            startSegmentWorkerIfNeeded()
        }
    }

    func startSegmentWorkerIfNeeded() {
        guard maintenanceLease == nil, !isRecoveryRunning,
              !isCompactionSuspended, !isSegmentWorkerRunning
        else { return }
        isSegmentWorkerRunning = true
        signalStateTransition()
        segmentWorkerTask = Task(priority: .background) { await self.runSegmentJobs() }
    }

    func runSegmentJobs() async {
        defer {
            isSegmentWorkerRunning = false
            segmentWorkerTask = nil
            if restartSegmentWorkerWhenStopped, !isCompactionSuspended {
                restartSegmentWorkerWhenStopped = false
                startSegmentWorkerIfNeeded()
            }
            signalStateTransition()
        }
        while maintenanceLease == nil, !isRecoveryRunning,
              !isCompactionSuspended, !Task.isCancelled
        {
            let lease: SegmentJobLease
            do {
                guard let next = try await persistence.leaseSegmentJob(workerID, now(), configuration.leaseDuration) else {
                    if failedJobsBySession.values.contains(where: { !$0.isEmpty }) {
                        scheduleSegmentRetry()
                    }
                    return
                }
                lease = next
            } catch is CancellationError {
                return
            } catch {
                degrade(.recoveryFailed(message: String(describing: error)))
                scheduleSegmentRetry()
                return
            }
            await process(lease)
        }
    }

    func scheduleSegmentRetry() {
        guard !isSegmentRetryScheduled else { return }
        isSegmentRetryScheduled = true
        Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.restartSegmentWorkerAfterDelay()
        }
    }

    func restartSegmentWorkerAfterDelay() async {
        while isSegmentWorkerRunning {
            let observedGeneration = stateGeneration
            await waitForStateTransition(after: observedGeneration)
        }
        isSegmentRetryScheduled = false
        startSegmentWorkerIfNeeded()
    }

    func process(_ lease: SegmentJobLease) async {
        let manifest = lease.manifest
        do {
            try Task.checkCancellation()
            let verification: SegmentWriteVerification
            if await fileStorage.fileExists(manifest.finalURL) {
                do {
                    verification = try await segmentWriter.verifyPublished(manifest)
                } catch is CancellationError {
                    throw CancellationError()
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
        } catch is CancellationError {
            do {
                try await persistence.requeueSegmentJob(manifest.jobID, lease.workerID)
            } catch {
                degrade(.recoveryFailed(message: String(describing: error)))
            }
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

    func releaseCommittedSpoolPressure(_ urls: [URL]) {
        for url in urls {
            if let byteCount = knownSpoolBytes.removeValue(forKey: url) {
                spoolBytes = max(0, spoolBytes - byteCount)
            }
        }
    }

    func recoverCommittedSpoolCleanup() async throws {
        var budget = StorageCPUBudget()
        for cleanup in try await persistence.pendingSegmentCleanups() {
            _ = try await fileStorage.removeFilesStrict(cleanup.spoolURLs)
            try await persistence.completeSegmentCleanup(cleanup.jobID)
            try await budget.pace()
        }
    }

    func recoverSpoolJournal() async throws {
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

    func recoverSegmentJournal() async throws {
        let items = try await persistence.recoverSegmentJobs(now())
        for item in items {
            if await fileStorage.fileExists(item.manifest.finalURL) { continue }
            if await fileStorage.fileExists(item.manifest.partialURL) {
                _ = try await fileStorage.removeFiles([item.manifest.partialURL])
            }
        }
    }

    func loadPendingFrames() async throws -> Int {
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
