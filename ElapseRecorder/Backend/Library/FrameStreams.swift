import Foundation

/// Sendable persistence endpoints used to restart a query stream without retaining its records.
nonisolated struct FramePageLoader {
    var page: @Sendable (_ query: FrameQuery, _ after: FrameCursor?, _ limit: Int) async throws -> FramePage
    var count: @Sendable (_ query: FrameQuery) async throws -> Int
    var snapshot: @Sendable (_ query: FrameQuery) async throws -> FrameQuerySnapshot
    var byID: @Sendable (_ ids: [UUID]) async throws -> [ScreenshotRecord]

    init(persistence: PersistenceClient) {
        page = persistence.framePage
        snapshot = persistence.frameQuerySnapshot
        count = persistence.frameCount
        byID = persistence.framesByID
    }

    func count(for selection: FrameSelection) async throws -> Int {
        switch selection {
        case let .query(query):
            return try await count(query)
        case let .ids(ids):
            return ids.count
        }
    }

    func snapshot(for selection: FrameSelection) async throws -> FrameQuerySnapshot {
        switch selection {
        case let .query(query):
            return try await snapshot(query)
        case let .ids(ids):
            return FrameQuerySnapshot(selection: selection, count: ids.count)
        }
    }

    /// Returns a restartable stream. Query and explicit-id paths both fetch fixed-size pages and
    /// yield one descriptor at a time, so consumers never retain the complete frame array.
    func records(
        for selection: FrameSelection,
        pageSize: Int = 256
    ) -> AsyncThrowingStream<ScreenshotRecord, Error> {
        let boundedPageSize = min(1000, max(1, pageSize))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch selection {
                    case let .query(query):
                        var cursor: FrameCursor?
                        repeat {
                            try Task.checkCancellation()
                            let loaded = try await page(query, cursor, boundedPageSize)
                            for frame in loaded.frames {
                                continuation.yield(frame)
                            }
                            guard loaded.nextCursor != cursor else {
                                // A malformed persistence implementation must not spin forever.
                                cursor = nil
                                break
                            }
                            cursor = loaded.nextCursor
                        } while cursor != nil

                    case let .ids(ids):
                        var start = ids.startIndex
                        while start < ids.endIndex {
                            try Task.checkCancellation()
                            let end = ids.index(start, offsetBy: boundedPageSize, limitedBy: ids.endIndex) ?? ids.endIndex
                            for frame in try await byID(Array(ids[start ..< end])) {
                                continuation.yield(frame)
                            }
                            start = end
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func exportFrames(
        for selection: FrameSelection,
        pageSize: Int = 256
    ) -> AsyncThrowingStream<ExportFrame, Error> {
        let records = records(for: selection, pageSize: pageSize)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await record in records {
                        continuation.yield(ExportFrame(record: record))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func averageInterval(for selection: FrameSelection) async throws -> TimeInterval? {
        struct WindowRun: Hashable {
            let sessionID: UUID
            let windowID: UUID
        }

        var previousByRun: [WindowRun: Date] = [:]
        var intervalTotal: TimeInterval = 0
        var intervalCount = 0
        for try await record in records(for: selection) {
            let run = WindowRun(sessionID: record.sessionID, windowID: record.windowID)
            if let previous = previousByRun[run] {
                intervalTotal += max(0, record.capturedAt.timeIntervalSince(previous))
                intervalCount += 1
            }
            previousByRun[run] = record.capturedAt
        }
        guard intervalCount > 0 else { return nil }
        return intervalTotal / Double(intervalCount)
    }
}

nonisolated extension ExportFrame {
    init(record: ScreenshotRecord) {
        self.init(
            url: record.fileURL,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            capturedAt: record.capturedAt,
            perceptualHash: record.perceptualHash,
            videoURL: record.videoURL,
            videoFrameIndex: record.videoFrameIndex,
            videoPTSValue: record.videoPTSValue,
            videoPTSTimescale: record.videoPTSTimescale
        )
    }
}

/// Builds the option-filtered export source and computes its exact count with the same streaming
/// state machine. This preserves progress/output-count semantics without retaining frame records.
nonisolated enum ExportFrameStreams {
    typealias MissingHashResolver = @Sendable (ExportFrame) async throws -> UInt64

    static func storedHashes(in source: ExportFrameStream) async throws -> [UInt64] {
        var hashes: [UInt64] = []
        hashes.reserveCapacity(source.count)
        for try await frame in source.stream() {
            hashes.append(frame.perceptualHash)
        }
        return hashes
    }

    static func filtered(
        source: ExportFrameStream,
        options: ExportOptions,
        resolveMissingHash: @escaping MissingHashResolver
    ) async throws -> ExportFrameStream {
        var resolvedHashes: [UInt64] = []
        if options.skipSimilarFrames {
            resolvedHashes.reserveCapacity(source.count)
            for try await frame in source.stream() {
                try resolvedHashes.append(
                    frame.perceptualHash == 0
                        ? await resolveMissingHash(frame)
                        : frame.perceptualHash
                )
            }
        }

        let candidateCount = options.skipSimilarFrames ? resolvedHashes.count : source.count
        var previousHash: UInt64?
        var selectedCount = 0
        for index in 0 ..< candidateCount {
            if shouldKeep(
                index: index,
                options: options,
                hashes: resolvedHashes,
                previousHash: &previousHash
            ) {
                selectedCount += 1
            }
        }
        let immutableHashes = resolvedHashes

        return ExportFrameStream(selection: source.selection, count: selectedCount) {
            selectedFrames(source: source, options: options, resolvedHashes: immutableHashes)
        }
    }

    private static func selectedFrames(
        source: ExportFrameStream,
        options: ExportOptions,
        resolvedHashes: [UInt64]
    ) -> AsyncThrowingStream<ExportFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sourceIndex = 0
                    var previousHash: UInt64?
                    for try await frame in source.stream() {
                        defer { sourceIndex += 1 }
                        guard shouldKeep(
                            index: sourceIndex,
                            options: options,
                            hashes: resolvedHashes,
                            previousHash: &previousHash
                        ) else { continue }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func shouldKeep(
        index: Int,
        options: ExportOptions,
        hashes: [UInt64],
        previousHash: inout UInt64?
    ) -> Bool {
        if let trim = options.trimRange, !trim.contains(index) { return false }
        guard options.skipSimilarFrames, hashes.indices.contains(index) else { return true }
        let hash = hashes[index]
        if let previousHash,
           PerceptualHash.distance(previousHash, hash) <= ExportFrameFilter.similarityThreshold
        {
            return false
        }
        previousHash = hash
        return true
    }
}
