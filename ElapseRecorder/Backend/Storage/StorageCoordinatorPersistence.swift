import ComposableArchitecture
import CoreGraphics
import Foundation

extension StorageCoordinator {
    func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    func emit(_ event: StorageCoordinatorEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func degrade(_ reason: StorageDegradation) {
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

    func resolve(_ predicate: (StorageDegradation) -> Bool) {
        let wasDegraded = !activeDegradations.isEmpty
        activeDegradations = Set(activeDegradations.filter { !predicate($0) })
        if wasDegraded, activeDegradations.isEmpty {
            emit(.storageResumed)
        }
    }

    func resolveFramePathDegradations() {
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

    func scheduleHealthProbe() {
        guard !isHealthProbeScheduled else { return }
        isHealthProbeScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.performHealthProbe()
        }
    }

    func performHealthProbe() async {
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

    func drainQueue() async {
        while !queue.isEmpty {
            let frame = queue.removeFirst()
            processingFrame = frame
            await persist(frame)
            processingFrame = nil
        }
        isDrainingQueue = false
        resolve { if case .queueFull = $0 { true } else { false } }
    }

    func persist(_ envelope: CapturedFrameEnvelope) async {
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
}
