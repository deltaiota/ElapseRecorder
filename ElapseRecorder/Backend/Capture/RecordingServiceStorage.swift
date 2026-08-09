import Chronicle
import Foundation

extension RecordingService {
    func receiveStorageEvent(_ event: StorageCoordinatorEvent) {
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

    func pauseForStorageDegradation(_ degradation: StorageDegradation) {
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

    func resumeAfterStorageRecovery() {
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

    func correlatedRun(_ handle: RecordingSessionHandle) -> Run? {
        guard let run = runsBySessionID[handle.sessionID], run.handle == handle else { return nil }
        return run
    }

    func runForActiveCycle(_ token: CycleToken) -> Run? {
        guard let run = correlatedRun(token.handle),
              run.activeCycleSequences.contains(token.sequence)
        else { return nil }
        return run
    }

    func emitDiagnostic(_ diagnostic: CaptureDiagnostic) {
        emit(.diagnostic(diagnostic))
    }

    func normalizedWindowTitle(_ raw: String?) -> String? {
        guard let title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return title
    }
}
