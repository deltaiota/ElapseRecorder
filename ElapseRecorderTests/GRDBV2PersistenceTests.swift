@testable import ElapseRecorder
import Foundation
import XCTest

final class GRDBV2PersistenceTests: XCTestCase {
    func testSchemaIsVersionedAndIndexedForV2Queries() async throws {
        let (database, _) = try temporaryBackend()

        let migrations = try await database.appliedMigrationIdentifiers()
        let tables = try Set(await database.schemaTableNames())
        let indexes = try Set(await database.schemaIndexNames())
        XCTAssertEqual(Set(migrations), [
            CaptureDatabaseSchema.migrationV1,
            CaptureDatabaseSchema.migrationV2,
            CaptureDatabaseSchema.migrationV3,
        ])
        XCTAssertTrue(tables.isSuperset(of: [
            "sessions", "windows", "title_observations", "frames", "unavailable_spans",
            "media_assets", "segment_jobs", "segment_job_frames",
            "storage_deletion_tombstones", "storage_deletion_sessions", "storage_deletion_files",
        ]))
        XCTAssertTrue(indexes.isSuperset(of: [
            "sessions_by_app_time", "frames_by_window_time", "frames_by_session_time",
            "frames_by_capture_time", "assets_by_session_state", "jobs_by_state_retry",
        ]))
    }

    func testSpoolJournalTransitionsAndKeysetPagination() async throws {
        let (_, client) = try temporaryBackend()
        let sessionID = UUID()
        let windowID = UUID()
        try await insertSessionAndWindow(client: client, sessionID: sessionID, windowID: windowID)

        let first = try registration(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            sessionID: sessionID,
            windowID: windowID,
            completedAt: Date(timeIntervalSince1970: 10)
        )
        let second = try registration(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            sessionID: sessionID,
            windowID: windowID,
            completedAt: Date(timeIntervalSince1970: 20)
        )

        try await client.registerSpoolFrame(first)
        let initialRecovery = try await client.recoverSpoolFrames(10)
        let initialPending = try await client.pendingSpoolFrames(10)
        let initialBytes = try await client.spoolByteCount()
        let hiddenCount = try await client.frameCount(FrameQuery(scope: .session(id: sessionID)))
        XCTAssertEqual(initialRecovery.map(\.state), [.registered])
        XCTAssertEqual(initialPending, [])
        XCTAssertEqual(initialBytes, 0)
        XCTAssertEqual(hiddenCount, 0)

        let storedFirst = try await client.markSpoolFrameReady(first.id, 101)
        XCTAssertEqual(storedFirst.registration, first)
        XCTAssertEqual(storedFirst.byteCount, 101)
        try await client.registerSpoolFrame(second)
        _ = try await client.markSpoolFrameReady(second.id, 202)
        let readyBytes = try await client.spoolByteCount()
        XCTAssertEqual(readyBytes, 303)

        let query = FrameQuery(scope: .session(id: sessionID))
        let firstPage = try await client.framePage(query, nil, 1)
        XCTAssertEqual(firstPage.frames.map(\.id), [first.id])
        XCTAssertEqual(firstPage.totalCount, 2)
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        let secondPage = try await client.framePage(query, cursor, 1)
        XCTAssertEqual(secondPage.frames.map(\.id), [second.id])
        XCTAssertNil(secondPage.nextCursor)
        let selected = try await client.framesByID([second.id, first.id])
        XCTAssertEqual(selected.map(\.id), [second.id, first.id])
    }

    func testReadyPNGIsVisibleButNeverQueuedForHEVC() async throws {
        let (_, client) = try temporaryBackend()
        let sessionID = UUID()
        let windowID = UUID()
        try await insertSessionAndWindow(client: client, sessionID: sessionID, windowID: windowID)
        var png = registration(
            id: UUID(),
            sessionID: sessionID,
            windowID: windowID,
            completedAt: Date(timeIntervalSince1970: 10)
        )
        png.spoolURL = URL(filePath: "/tmp/\(png.id).png")
        png.format = .png
        try await client.registerSpoolFrame(png)
        _ = try await client.markSpoolFrameReady(png.id, 400)

        let pending = try await client.pendingSpoolFrames(10)
        let transientBytes = try await client.spoolByteCount()
        let visible = try await client.screenshotsForSession(sessionID)
        XCTAssertEqual(pending, [])
        XCTAssertEqual(transientBytes, 0)
        XCTAssertEqual(visible.map(\.id), [png.id])
        XCTAssertEqual(visible.first?.frameSource, .file(png.spoolURL))
    }

    func testSegmentCommitUsesExactRationalPTSAndRepresentsMediaOnce() async throws {
        let (_, client) = try temporaryBackend()
        let sessionID = UUID()
        let windowID = UUID()
        try await insertSessionAndWindow(client: client, sessionID: sessionID, windowID: windowID)

        let first = registration(id: UUID(), sessionID: sessionID, windowID: windowID, completedAt: Date(timeIntervalSince1970: 10))
        let second = registration(id: UUID(), sessionID: sessionID, windowID: windowID, completedAt: Date(timeIntervalSince1970: 20))
        for frame in [first, second] {
            try await client.registerSpoolFrame(frame)
            _ = try await client.markSpoolFrameReady(frame.id, 100)
        }

        let jobID = UUID()
        let assetID = UUID()
        let finalURL = URL(filePath: "/tmp/\(assetID).mov")
        let manifest = SegmentJobManifest(
            jobID: jobID,
            assetID: assetID,
            handle: RecordingSessionHandle(
                sessionID: sessionID,
                bundleIdentifier: "com.example.Persistence",
                processIdentifier: 42,
                generation: 1
            ),
            windowID: windowID,
            partialURL: URL(filePath: "/tmp/\(assetID).partial.mov"),
            finalURL: finalURL,
            canvasWidth: 1920,
            canvasHeight: 1080,
            frames: [
                SegmentFrameInput(frameID: first.id, spoolURL: first.spoolURL, ptsValue: 5, ptsTimescale: 600),
                SegmentFrameInput(frameID: second.id, spoolURL: second.spoolURL, ptsValue: 17, ptsTimescale: 600),
            ],
            createdAt: Date(timeIntervalSince1970: 30)
        )
        try await client.createSegmentJob(manifest)
        var workerID = UUID()
        let leased = try await client.leaseSegmentJob(workerID, Date(timeIntervalSince1970: 31), 60)
        XCTAssertEqual(try XCTUnwrap(leased).manifest, manifest)

        try await client.requeueSegmentJob(jobID, workerID)
        workerID = UUID()
        let reLeased = try await client.leaseSegmentJob(workerID, Date(timeIntervalSince1970: 32), 60)
        XCTAssertEqual(try XCTUnwrap(reLeased).manifest, manifest)

        let commit = SegmentJobCommit(
            jobID: jobID,
            workerID: workerID,
            assetID: assetID,
            finalURL: finalURL,
            byteCount: 151,
            frameCount: 2,
            canvasWidth: 1920,
            canvasHeight: 1080
        )
        try await client.markSegmentJobPublished(commit)
        let cleanup = try await client.commitSegmentJob(commit)
        let pendingCleanup = try await client.pendingSegmentCleanups()
        XCTAssertEqual(pendingCleanup.map(\.jobID), [jobID])
        XCTAssertEqual(Set(pendingCleanup.first?.spoolURLs ?? []), Set([first.spoolURL, second.spoolURL]))
        let committedSpoolBytes = try await client.spoolByteCount()
        XCTAssertEqual(committedSpoolBytes, 0)
        try await client.completeSegmentCleanup(jobID)
        let remainingCleanup = try await client.pendingSegmentCleanups()
        XCTAssertEqual(remainingCleanup, [])
        XCTAssertEqual(Set(cleanup), Set([first.spoolURL, second.spoolURL]))
        let remainingSpoolBytes = try await client.spoolByteCount()
        XCTAssertEqual(remainingSpoolBytes, 0)

        let records = try await client.screenshotsForSession(sessionID)
        XCTAssertEqual(records.map(\.videoURL), [finalURL, finalURL])
        XCTAssertEqual(records.map(\.videoPTSValue), [5, 17])
        XCTAssertEqual(records.map(\.videoPTSTimescale), [600, 600])
        let files = try await client.screenshotFileIndex()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, finalURL.path)
        XCTAssertEqual(files.first?.sizeBytes, 151)
    }

    func testSessionDeletionTombstoneHidesRowsAndRecoversManifest() async throws {
        let (_, client) = try temporaryBackend()
        let sessionID = UUID()
        let windowID = UUID()
        try await insertSessionAndWindow(client: client, sessionID: sessionID, windowID: windowID)
        let frame = registration(id: UUID(), sessionID: sessionID, windowID: windowID, completedAt: Date(timeIntervalSince1970: 10))
        try await client.registerSpoolFrame(frame)
        _ = try await client.markSpoolFrameReady(frame.id, 80)
        try await client.closeSession(sessionID, Date(timeIntervalSince1970: 20))

        let snapshot = try await client.retentionSnapshot()
        XCTAssertEqual(snapshot.endedSessionsOldestFirst.map(\.id), [sessionID])
        let prepared = try await client.prepareSessionDeletion([sessionID])
        let manifest = try XCTUnwrap(prepared)
        XCTAssertEqual(manifest.sessions.map(\.id), [sessionID])
        XCTAssertEqual(manifest.fileURLs, [frame.spoolURL])
        let visibleSessions = try await client.sessions("com.example.Persistence")
        let visibleFrames = try await client.screenshotsForApp("com.example.Persistence")
        let pending = try await client.pendingSessionDeletions()
        XCTAssertEqual(visibleSessions, [])
        XCTAssertEqual(visibleFrames, [])
        XCTAssertEqual(pending, [manifest])

        try await client.finalizeSessionDeletion(manifest.id)
        let remaining = try await client.pendingSessionDeletions()
        XCTAssertEqual(remaining, [])
    }

    private func temporaryBackend() throws -> (ElapseDatabase, PersistenceClient) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ElapseRecorder-V2Tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let database = try ElapseDatabase(url: directory.appending(path: "metadata.sqlite"))
        return (database, .live(database: database))
    }

    private func insertSessionAndWindow(
        client: PersistenceClient,
        sessionID: UUID,
        windowID: UUID
    ) async throws {
        try await client.openSession(CaptureSession(
            id: sessionID,
            bundleIdentifier: "com.example.Persistence",
            displayName: "Persistence",
            processIdentifier: 42,
            startedAt: Date(timeIntervalSince1970: 1)
        ))
        try await client.upsertWindow(MonitoredWindow(
            id: windowID,
            sessionID: sessionID,
            systemWindowID: 7,
            displayNumber: 1,
            label: "Window",
            firstSeenAt: Date(timeIntervalSince1970: 2),
            lastSeenAt: Date(timeIntervalSince1970: 2)
        ))
    }

    private func registration(
        id: UUID,
        sessionID: UUID,
        windowID: UUID,
        completedAt: Date
    ) -> SpoolFrameRegistration {
        SpoolFrameRegistration(
            id: id,
            sessionID: sessionID,
            windowID: windowID,
            bundleIdentifier: "com.example.Persistence",
            processIdentifier: 42,
            generation: 1,
            cycleSequence: Int64(completedAt.timeIntervalSince1970),
            scheduledOffsetNanoseconds: Int64(completedAt.timeIntervalSince1970 * 1_000_000_000),
            requestStartedAt: completedAt.addingTimeInterval(-0.1),
            completedAt: completedAt,
            spoolURL: URL(filePath: "/tmp/\(id).heic"),
            format: .heic,
            pixelWidth: 1920,
            pixelHeight: 1080,
            perceptualHash: UInt64(completedAt.timeIntervalSince1970)
        )
    }
}
