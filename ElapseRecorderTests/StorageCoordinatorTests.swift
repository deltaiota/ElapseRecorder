import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class StorageCoordinatorTests: XCTestCase {
    func testQueueBackpressureIsExplicitAndHardBounded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = StorageRepositoryDouble()
        let gate = SuspensionGate()
        let client = makeClient(
            directory: directory,
            repository: repository,
            configuration: Self.configuration(queueCapacity: 1),
            imageEncoder: ImageEncodingClient { _, _ in
                await gate.wait()
                return Data("heic".utf8)
            }
        )
        var events = await client.events().makeAsyncIterator()
        let first = envelope(id: UUID(), sessionID: UUID())
        let second = envelope(id: UUID(), sessionID: first.handle.sessionID)

        let firstResult = await client.enqueue(first)
        let secondResult = await client.enqueue(second)
        XCTAssertEqual(firstResult, .accepted(frameID: first.id))
        XCTAssertEqual(secondResult, .backpressured(capacity: 1))
        await gate.open()
        _ = try await nextCommittedFrame(&events)
    }

    func testFlushSealsShortSessionAndDefersSpoolCleanupUntilRecovery() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = StorageRepositoryDouble()
        let client = makeClient(
            directory: directory,
            repository: repository,
            configuration: Self.configuration(maximumFrames: 100)
        )
        var events = await client.events().makeAsyncIterator()
        let frame = envelope(id: UUID(), sessionID: UUID())

        let enqueueResult = await client.enqueue(frame)
        XCTAssertEqual(enqueueResult, .accepted(frameID: frame.id))
        let stored = try await nextCommittedFrame(&events)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.spoolURL.path))

        try await client.flushSession(frame.handle)

        let commits = await repository.commits()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].frameCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: commits[0].finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.spoolURL.path))
        await client.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.spoolURL.path))
    }

    func testThresholdAutomaticallyPublishesVideoWithoutManualCompaction() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = StorageRepositoryDouble()
        let client = makeClient(
            directory: directory,
            repository: repository,
            configuration: Self.configuration(maximumFrames: 1)
        )
        var events = await client.events().makeAsyncIterator()
        let frame = envelope(id: UUID(), sessionID: UUID())

        let enqueueResult = await client.enqueue(frame)
        XCTAssertEqual(enqueueResult, .accepted(frameID: frame.id))
        let segmentURL = try await nextCommittedSegment(&events)

        XCTAssertTrue(FileManager.default.fileExists(atPath: segmentURL.path))
        let commits = await repository.commits()
        XCTAssertEqual(commits.count, 1)
    }

    func testPNGRemainsLosslessStandaloneOnThresholdAndFlush() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = StorageRepositoryDouble()
        let client = makeClient(
            directory: directory,
            repository: repository,
            configuration: Self.configuration(maximumFrames: 1, maximumSpoolBytes: 1),
            imageEncoder: ImageEncodingClient { _, options in
                XCTAssertEqual(options.format, .png)
                return Data("png".utf8)
            }
        )
        var events = await client.events().makeAsyncIterator()
        let frame = envelope(id: UUID(), sessionID: UUID(), format: .png)

        let enqueueResult = await client.enqueue(frame)
        XCTAssertEqual(enqueueResult, .accepted(frameID: frame.id))
        let stored = try await nextCommittedFrame(&events)
        try await client.flushSession(frame.handle)

        XCTAssertEqual(stored.format, .png)
        XCTAssertEqual(stored.spoolURL.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.spoolURL.path))
        let commits = await repository.commits()
        XCTAssertTrue(commits.isEmpty)
    }

    func testCommitFailureNeverDeletesPublishedVideoOrAuthoritativeSpool() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = StorageRepositoryDouble(commitFails: true)
        let client = makeClient(
            directory: directory,
            repository: repository,
            configuration: Self.configuration(maximumFrames: 1)
        )
        var events = await client.events().makeAsyncIterator()
        let frame = envelope(id: UUID(), sessionID: UUID())

        let enqueueResult = await client.enqueue(frame)
        XCTAssertEqual(enqueueResult, .accepted(frameID: frame.id))
        let stored = try await nextCommittedFrame(&events)
        let failure = try await nextSegmentFailure(&events)
        let recoveredManifest = await repository.manifest(id: failure)
        let manifest = try XCTUnwrap(recoveredManifest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.spoolURL.path))
    }

    func testRecoveryAdoptsPublishedSegmentOnceAndNeverDeletesCommittedVideo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = StorageRepositoryDouble()
        let handle = RecordingSessionHandle(
            sessionID: UUID(),
            bundleIdentifier: "com.example.Test",
            processIdentifier: 42,
            generation: 1
        )
        let frameID = UUID()
        let spoolURL = directory.appending(path: "\(frameID).heic")
        try Data("heic".utf8).write(to: spoolURL)
        let registration = SpoolFrameRegistration(
            id: frameID,
            sessionID: handle.sessionID,
            windowID: UUID(),
            bundleIdentifier: handle.bundleIdentifier,
            processIdentifier: handle.processIdentifier,
            generation: handle.generation,
            cycleSequence: 1,
            scheduledOffsetNanoseconds: 0,
            requestStartedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            spoolURL: spoolURL,
            format: .heic,
            pixelWidth: 2,
            pixelHeight: 2,
            perceptualHash: 0
        )
        await repository.insert(StoredSpoolFrame(registration: registration, byteCount: 4))
        let assetID = UUID()
        let manifest = SegmentJobManifest(
            jobID: UUID(),
            assetID: assetID,
            handle: handle,
            windowID: registration.windowID,
            partialURL: directory.appending(path: "\(assetID).partial.mov"),
            finalURL: directory.appending(path: "\(assetID).mov"),
            canvasWidth: 2,
            canvasHeight: 2,
            frames: [.init(frameID: frameID, spoolURL: spoolURL, ptsValue: 0, ptsTimescale: 30)],
            createdAt: Date(timeIntervalSince1970: 3)
        )
        try Data("movie".utf8).write(to: manifest.finalURL)
        await repository.insert(manifest)
        let client = makeClient(directory: directory, repository: repository)

        await client.recover()
        await client.recover()

        let commitCount = await repository.commits().count
        XCTAssertEqual(commitCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: spoolURL.path))
    }

    private func makeClient(
        directory: URL,
        repository: StorageRepositoryDouble,
        configuration: StorageCoordinatorConfiguration = StorageCoordinatorTests.configuration(),
        imageEncoder: ImageEncodingClient = ImageEncodingClient { _, _ in Data("heic".utf8) }
    ) -> StorageCoordinatorClient {
        var persistence = PersistenceClient.unimplemented
        persistence.registerSpoolFrame = { try await repository.register($0) }
        persistence.markSpoolFrameReady = { try await repository.markReady(id: $0, byteCount: $1) }
        persistence.failSpoolFrame = { try await repository.failFrame(id: $0, message: $1) }
        persistence.recoverSpoolFrames = { await repository.recoverFrames(limit: $0) }
        persistence.pendingSpoolFrames = { await repository.pendingFrames(limit: $0) }
        persistence.spoolByteCount = { await repository.spoolByteCount() }
        persistence.createSegmentJob = { try await repository.create($0) }
        persistence.leaseSegmentJob = { await repository.lease(workerID: $0, now: $1, duration: $2) }
        persistence.markSegmentJobPublished = { try await repository.markPublished($0) }
        persistence.commitSegmentJob = { try await repository.commit($0) }
        persistence.failSegmentJob = { await repository.failJob(id: $0, workerID: $1, message: $2, retryAt: $3, finalByteCount: $4) }
        persistence.recoverSegmentJobs = { await repository.recoverJobs(now: $0) }
        persistence.pendingSegmentCleanups = { await repository.pendingCleanups() }
        persistence.completeSegmentCleanup = { await repository.completeCleanup($0) }

        var files = FileStorageClient.liveValue
        files.spoolFrameURL = { _, windowID, frameID, format in
            let folder = directory.appending(path: "spool/\(windowID)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appending(path: "\(frameID).\(format.fileExtension)")
        }
        files.segmentAssetURLs = { _, assetID in
            (
                directory.appending(path: "\(assetID).partial.mov"),
                directory.appending(path: "\(assetID).mov")
            )
        }
        files.availableCapacity = { Int64.max }
        files.probeWritable = {}

        let writer = SegmentVideoWriterClient(
            writeAndVerify: { manifest, _ in
                try Data("movie".utf8).write(to: manifest.partialURL)
                return SegmentWriteVerification(
                    byteCount: 5,
                    sampleCount: manifest.frames.count,
                    canvasWidth: manifest.canvasWidth,
                    canvasHeight: manifest.canvasHeight
                )
            },
            verifyPublished: { manifest in
                SegmentWriteVerification(
                    byteCount: 5,
                    sampleCount: manifest.frames.count,
                    canvasWidth: manifest.canvasWidth,
                    canvasHeight: manifest.canvasHeight
                )
            }
        )
        return StorageCoordinatorClient.live(environment: StorageCoordinator.Environment(
            configuration: configuration,
            persistence: persistence,
            fileStorage: files,
            imageEncoder: imageEncoder,
            segmentWriter: writer,
            segmentQuality: { 0.65 },
            now: { Date(timeIntervalSince1970: 100) },
            makeID: { UUID() }
        ))
    }

    private static func configuration(
        queueCapacity: Int = 4,
        maximumFrames: Int = 10,
        maximumSpoolBytes: Int = 1024
    ) -> StorageCoordinatorConfiguration {
        StorageCoordinatorConfiguration(
            queueCapacity: queueCapacity,
            maximumSpoolBytes: maximumSpoolBytes,
            minimumFreeDiskBytes: 0,
            segmentTarget: SegmentTarget(
                maximumFrames: maximumFrames,
                maximumDuration: 60,
                maximumBytes: 1024
            ),
            mediaTimescale: 30,
            leaseDuration: 60,
            recoveryBatchSize: 100
        )
    }

    private func envelope(
        id: UUID,
        sessionID: UUID,
        format: CaptureImageFormat = .heic
    ) -> CapturedFrameEnvelope {
        let image = makeImage()
        return CapturedFrameEnvelope(
            id: id,
            handle: RecordingSessionHandle(
                sessionID: sessionID,
                bundleIdentifier: "com.example.Test",
                processIdentifier: 42,
                generation: 1
            ),
            cycleSequence: 1,
            scheduledOffsetNanoseconds: 0,
            requestStartedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            window: CapturedWindowMetadata(
                windowID: UUID(),
                systemWindowID: 7,
                displayNumber: 1,
                title: "Test"
            ),
            image: ImmutableCapturedImage(image),
            encodingOptions: CaptureEncodingOptions(format: format, heicQuality: 0.82)
        )
    }

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "storage-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func nextCommittedFrame(
        _ events: inout AsyncStream<StorageCoordinatorEvent>.AsyncIterator
    ) async throws -> StoredSpoolFrame {
        while let event = await events.next() {
            if case let .frameCommitted(frame) = event { return frame }
        }
        throw StorageTestError.missingEvent
    }

    private func nextCommittedSegment(
        _ events: inout AsyncStream<StorageCoordinatorEvent>.AsyncIterator
    ) async throws -> URL {
        while let event = await events.next() {
            if case let .segmentCommitted(_, _, _, url) = event { return url }
        }
        throw StorageTestError.missingEvent
    }

    private func nextSegmentFailure(
        _ events: inout AsyncStream<StorageCoordinatorEvent>.AsyncIterator
    ) async throws -> UUID {
        while let event = await events.next() {
            if case let .storageDegraded(.segmentFailed(jobID, _)) = event { return jobID }
        }
        throw StorageTestError.missingEvent
    }
}

private enum StorageTestError: Error {
    case forcedCommitFailure
    case missingEvent
    case missingRegistration
}

private actor SuspensionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

private actor StorageRepositoryDouble {
    private var registrations: [UUID: SpoolFrameRegistration] = [:]
    private var frames: [UUID: StoredSpoolFrame] = [:]
    private var jobs: [UUID: SegmentJobManifest] = [:]
    private var leases: [UUID: UUID] = [:]
    private var committedJobIDs = Set<UUID>()
    private var published = Set<UUID>()
    private var pendingCleanupJobs: [UUID: [URL]] = [:]
    private var committed: [SegmentJobCommit] = []
    private var failedJobs = Set<UUID>()
    private let commitFails: Bool

    init(commitFails: Bool = false) {
        self.commitFails = commitFails
    }

    func register(_ registration: SpoolFrameRegistration) throws {
        registrations[registration.id] = registration
    }

    func markReady(id: UUID, byteCount: Int) throws -> StoredSpoolFrame {
        guard let registration = registrations[id] else { throw StorageTestError.missingRegistration }
        let frame = StoredSpoolFrame(registration: registration, byteCount: byteCount)
        frames[id] = frame
        return frame
    }

    func failFrame(id: UUID, message _: String) throws {
        registrations[id] = nil
    }

    func recoverFrames(limit _: Int) -> [SpoolFrameRecoveryItem] {
        []
    }

    func pendingFrames(limit: Int) -> [StoredSpoolFrame] {
        let jobFrameIDs = Set(jobs.values.flatMap { $0.frames.map(\.frameID) })
        return Array(frames.values.filter { !jobFrameIDs.contains($0.id) }.prefix(limit))
    }

    func spoolByteCount() -> Int {
        frames.values.reduce(0) { $0 + $1.byteCount }
    }

    func create(_ manifest: SegmentJobManifest) throws {
        jobs[manifest.jobID] = manifest
    }

    func lease(workerID: UUID, now: Date, duration: TimeInterval) -> SegmentJobLease? {
        guard let manifest = jobs.values
            .filter({ !failedJobs.contains($0.jobID) && !committedJobIDs.contains($0.jobID) })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first,
            leases[manifest.jobID] == nil
        else { return nil }
        leases[manifest.jobID] = workerID
        return SegmentJobLease(
            manifest: manifest,
            workerID: workerID,
            expiresAt: now.addingTimeInterval(duration)
        )
    }

    func markPublished(_ publication: SegmentJobCommit) throws {
        guard leases[publication.jobID] == publication.workerID else { throw StorageTestError.forcedCommitFailure }
        published.insert(publication.jobID)
    }

    func commit(_ commit: SegmentJobCommit) throws -> [URL] {
        if commitFails { throw StorageTestError.forcedCommitFailure }
        guard published.contains(commit.jobID), let manifest = jobs[commit.jobID] else { return [] }
        leases[commit.jobID] = nil
        committedJobIDs.insert(commit.jobID)
        failedJobs.remove(commit.jobID)
        committed.append(commit)
        let urls = manifest.frames.map(\.spoolURL)
        pendingCleanupJobs[commit.jobID] = urls
        return urls
    }

    func failJob(id: UUID, workerID _: UUID, message _: String, retryAt _: Date, finalByteCount _: Int) {
        leases[id] = nil
        failedJobs.insert(id)
    }

    func recoverJobs(now _: Date) -> [SegmentRecoveryItem] {
        leases.removeAll()
        failedJobs.removeAll()
        return jobs.values.map { SegmentRecoveryItem(manifest: $0, state: .queued, workerID: nil) }
    }

    func pendingCleanups() -> [SegmentCleanupManifest] {
        pendingCleanupJobs.map { SegmentCleanupManifest(jobID: $0.key, spoolURLs: $0.value) }
    }

    func completeCleanup(_ jobID: UUID) {
        guard let manifest = jobs.removeValue(forKey: jobID) else { return }
        committedJobIDs.remove(jobID)
        pendingCleanupJobs[jobID] = nil
        published.remove(jobID)
        for frame in manifest.frames {
            frames[frame.frameID] = nil
        }
    }

    func insert(_ frame: StoredSpoolFrame) {
        registrations[frame.id] = frame.registration
        frames[frame.id] = frame
    }

    func insert(_ manifest: SegmentJobManifest) {
        jobs[manifest.jobID] = manifest
    }

    func manifest(id: UUID) -> SegmentJobManifest? {
        jobs[id]
    }

    func commits() -> [SegmentJobCommit] {
        committed
    }
}
