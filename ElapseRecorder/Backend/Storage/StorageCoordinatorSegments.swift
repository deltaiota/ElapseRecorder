import ComposableArchitecture
import CoreGraphics
import Foundation

extension StorageCoordinator {
    func relieveSpoolPressure() async {
        let keys = Array(accumulators.keys)
        for key in keys {
            _ = await attemptSeal(key)
        }
        startSegmentWorkerIfNeeded()
    }

    func account(_ frame: StoredSpoolFrame) {
        guard frame.format == .heic, knownSpoolBytes[frame.spoolURL] == nil else { return }
        knownSpoolBytes[frame.spoolURL] = frame.byteCount
        spoolBytes += frame.byteCount
    }

    func accumulate(_ frame: StoredSpoolFrame) async {
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

    func deferFrame(_ frame: StoredSpoolFrame, for key: WindowKey) {
        guard deferredFrames[key]?.contains(where: { $0.id == frame.id }) != true else { return }
        deferredFrames[key, default: []].append(frame)
    }

    func shouldSeal(_ frames: [StoredSpoolFrame]) -> Bool {
        guard let first = frames.first, let last = frames.last else { return false }
        let totalBytes = frames.reduce(into: 0) { $0 += $1.byteCount }
        let duration = max(0, last.completedAt.timeIntervalSince(first.completedAt))
        return frames.count >= configuration.segmentTarget.maximumFrames
            || duration >= configuration.segmentTarget.maximumDuration
            || totalBytes >= configuration.segmentTarget.maximumBytes
    }

    func wouldExceedSegment(_ frames: [StoredSpoolFrame], adding frame: StoredSpoolFrame) -> Bool {
        guard let first = frames.first else { return false }
        let bytes = frames.reduce(frame.byteCount) { $0 + $1.byteCount }
        let duration = max(0, frame.completedAt.timeIntervalSince(first.completedAt))
        return frames.count + 1 > configuration.segmentTarget.maximumFrames
            || duration > configuration.segmentTarget.maximumDuration
            || bytes > configuration.segmentTarget.maximumBytes
    }

    func attemptSeal(_ key: WindowKey) async -> Bool {
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

    func scheduleSealRetry(_ key: WindowKey) {
        guard sealRetryScheduled.insert(key).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.retrySealAfterDelay(key)
        }
    }

    func retrySealAfterDelay(_ key: WindowKey) async {
        sealRetryScheduled.remove(key)
        while maintenanceLease != nil {
            await Task.yield()
        }
        guard accumulators[key]?.isEmpty == false || deferredFrames[key]?.isEmpty == false else { return }
        _ = await attemptSeal(key)
    }

    func sealAccumulator(_ key: WindowKey) async throws {
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

    func even(_ value: Int) -> Int {
        max(2, value + (value % 2))
    }
}
