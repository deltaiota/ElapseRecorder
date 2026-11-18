import Foundation
import GRDB

nonisolated extension GRDBPersistenceStore {
    func createSegmentJob(_ manifest: SegmentJobManifest) async throws {
        guard !manifest.frames.isEmpty, manifest.canvasWidth > 0, manifest.canvasHeight > 0,
              manifest.frames.allSatisfy({ $0.spoolURL.pathExtension.lowercased() == "heic" })
        else {
            throw PersistenceStoreError.invalidSegmentManifest(manifest.jobID)
        }
        try await database.pool.write { db in
            try Self.requireSessionAndWindow(sessionID: manifest.sessionID, windowID: manifest.windowID, db: db)
            guard let session = try Row.fetchOne(
                db,
                sql: "SELECT bundle_identifier, process_identifier FROM sessions WHERE id = ?",
                arguments: [manifest.sessionID.databaseID]
            ), session["bundle_identifier"] as String == manifest.handle.bundleIdentifier,
            session["process_identifier"] as Int64 == Int64(manifest.handle.processIdentifier)
            else { throw PersistenceStoreError.invalidSegmentManifest(manifest.jobID) }
            let frameIDs = manifest.frames.map(\.frameID.databaseID)
            let placeholders = Self.placeholders(frameIDs.count)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT f.id, f.session_id, f.window_id, f.spool_path, f.image_format,
                       f.process_identifier, f.generation, a.kind, a.state
                FROM frames f JOIN media_assets a ON a.id = f.asset_id
                WHERE f.id IN (\(placeholders))
                """,
                arguments: StatementArguments(frameIDs)
            )
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String, $0) })
            for input in manifest.frames {
                guard let row = byID[input.frameID.databaseID],
                      row["session_id"] as String == manifest.sessionID.databaseID,
                      row["window_id"] as String == manifest.windowID.databaseID,
                      row["spool_path"] as String == input.spoolURL.path(percentEncoded: false),
                      row["image_format"] as String == CaptureImageFormat.heic.rawValue,
                      row["process_identifier"] as Int64 == Int64(manifest.handle.processIdentifier),
                      row["generation"] as Int64 == Int64(bitPattern: manifest.handle.generation),
                      row["kind"] as String == MediaAssetKind.spoolImage.rawValue,
                      row["state"] as String == MediaAssetState.ready.rawValue
                else { throw PersistenceStoreError.invalidSegmentManifest(manifest.jobID) }
            }
            let finalPath = manifest.finalURL.path(percentEncoded: false)
            if try (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_assets WHERE path = ? AND state = 'ready'", arguments: [finalPath]) ?? 0) > 0 {
                throw PersistenceStoreError.readyAssetAlreadyExists(finalPath)
            }
            try db.execute(
                sql: """
                INSERT INTO media_assets
                    (id, session_id, window_id, kind, state, path, byte_count, pixel_width, pixel_height, frame_count, created_at)
                VALUES (?, ?, ?, 'videoSegment', 'writing', ?, 0, ?, ?, ?, ?)
                """,
                arguments: [
                    manifest.assetID.databaseID, manifest.sessionID.databaseID, manifest.windowID.databaseID,
                    finalPath, manifest.canvasWidth, manifest.canvasHeight, manifest.frames.count, manifest.createdAt.databaseTime,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO segment_jobs
                    (id, asset_id, session_id, window_id, partial_path, final_path, canvas_width, canvas_height, state, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?)
                """,
                arguments: [
                    manifest.jobID.databaseID, manifest.assetID.databaseID, manifest.sessionID.databaseID,
                    manifest.windowID.databaseID, manifest.partialURL.path(percentEncoded: false), finalPath,
                    manifest.canvasWidth, manifest.canvasHeight, manifest.createdAt.databaseTime,
                ]
            )
            for (ordinal, input) in manifest.frames.enumerated() {
                try db.execute(
                    sql: "INSERT INTO segment_job_frames (job_id, frame_id, ordinal, pts_value, pts_timescale) VALUES (?, ?, ?, ?, ?)",
                    arguments: [manifest.jobID.databaseID, input.frameID.databaseID, ordinal, input.ptsValue, input.ptsTimescale]
                )
            }
        }
    }

    func leaseSegmentJob(workerID: UUID, now: Date, leaseDuration: TimeInterval) async throws -> SegmentJobLease? {
        try await database.pool.write { db in
            guard let jobID = try String.fetchOne(
                db,
                sql: """
                SELECT j.id FROM segment_jobs j JOIN sessions s ON s.id = j.session_id
                WHERE s.state <> 'tombstoned' AND (
                    j.state = 'queued' OR (j.state = 'failed' AND (j.retry_at IS NULL OR j.retry_at <= ?))
                    OR (j.state = 'leased' AND j.lease_expires_at <= ?)
                )
                ORDER BY j.created_at, j.id LIMIT 1
                """,
                arguments: [now.databaseTime, now.databaseTime]
            ) else { return nil }
            let expiresAt = now.addingTimeInterval(max(1, leaseDuration))
            try db.execute(
                sql: """
                UPDATE segment_jobs
                SET state = 'leased', lease_worker_id = ?, lease_expires_at = ?, failure_message = NULL
                WHERE id = ?
                """,
                arguments: [workerID.databaseID, expiresAt.databaseTime, jobID]
            )
            try db.execute(
                sql: "UPDATE media_assets SET state = 'writing', failure_message = NULL WHERE id = (SELECT asset_id FROM segment_jobs WHERE id = ?)",
                arguments: [jobID]
            )
            guard let manifest = try Self.segmentManifest(jobID: jobID, db: db) else { return nil }
            return SegmentJobLease(manifest: manifest, workerID: workerID, expiresAt: expiresAt)
        }
    }

    func markSegmentJobPublished(_ publication: SegmentJobCommit) async throws {
        guard publication.byteCount > 0, publication.frameCount > 0,
              publication.canvasWidth > 0, publication.canvasHeight > 0
        else { throw PersistenceStoreError.segmentCommitMismatch(publication.jobID) }
        try await database.pool.write { db in
            guard let job = try Row.fetchOne(
                db,
                sql: "SELECT * FROM segment_jobs WHERE id = ?",
                arguments: [publication.jobID.databaseID]
            ) else { throw PersistenceStoreError.segmentJobNotFound(publication.jobID) }
            guard job["state"] as String == SegmentJobState.leased.rawValue else {
                throw PersistenceStoreError.segmentJobNotLeased(publication.jobID)
            }
            guard job["lease_worker_id"] as String? == publication.workerID.databaseID else {
                throw PersistenceStoreError.segmentLeaseOwnedByAnotherWorker(publication.jobID)
            }
            let frameCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM segment_job_frames WHERE job_id = ?",
                arguments: [publication.jobID.databaseID]
            ) ?? 0
            guard job["asset_id"] as String == publication.assetID.databaseID,
                  job["final_path"] as String == publication.finalURL.path(percentEncoded: false),
                  job["canvas_width"] as Int == publication.canvasWidth,
                  job["canvas_height"] as Int == publication.canvasHeight,
                  frameCount == publication.frameCount
            else { throw PersistenceStoreError.segmentCommitMismatch(publication.jobID) }
            try db.execute(
                sql: "UPDATE segment_jobs SET state = 'published' WHERE id = ?",
                arguments: [publication.jobID.databaseID]
            )
            try db.execute(
                sql: """
                UPDATE media_assets
                SET state = 'writing', byte_count = ?, pixel_width = ?, pixel_height = ?, frame_count = ?,
                    failure_message = NULL
                WHERE id = ? AND kind = 'videoSegment' AND state <> 'ready'
                """,
                arguments: [
                    publication.byteCount, publication.canvasWidth, publication.canvasHeight,
                    publication.frameCount, publication.assetID.databaseID,
                ]
            )
            guard db.changesCount == 1 else {
                throw PersistenceStoreError.segmentCommitMismatch(publication.jobID)
            }
        }
    }

    func commitSegmentJob(_ commit: SegmentJobCommit) async throws -> [URL] {
        guard commit.byteCount > 0, commit.frameCount > 0,
              commit.canvasWidth > 0, commit.canvasHeight > 0
        else { throw PersistenceStoreError.segmentCommitMismatch(commit.jobID) }
        return try await database.pool.write { db in
            guard let job = try Row.fetchOne(
                db,
                sql: "SELECT * FROM segment_jobs WHERE id = ?",
                arguments: [commit.jobID.databaseID]
            ) else { throw PersistenceStoreError.segmentJobNotFound(commit.jobID) }
            guard job["state"] as String == SegmentJobState.published.rawValue else {
                throw PersistenceStoreError.segmentJobNotLeased(commit.jobID)
            }
            guard job["lease_worker_id"] as String? == commit.workerID.databaseID else {
                throw PersistenceStoreError.segmentLeaseOwnedByAnotherWorker(commit.jobID)
            }
            let frameRows = try Row.fetchAll(
                db,
                sql: """
                SELECT jf.frame_id, jf.ordinal, jf.pts_value, jf.pts_timescale,
                       f.spool_path, f.asset_id AS spool_asset_id
                FROM segment_job_frames jf JOIN frames f ON f.id = jf.frame_id
                WHERE jf.job_id = ? ORDER BY jf.ordinal
                """,
                arguments: [commit.jobID.databaseID]
            )
            guard job["asset_id"] as String == commit.assetID.databaseID,
                  job["final_path"] as String == commit.finalURL.path(percentEncoded: false),
                  job["canvas_width"] as Int == commit.canvasWidth,
                  job["canvas_height"] as Int == commit.canvasHeight,
                  frameRows.count == commit.frameCount
            else { throw PersistenceStoreError.segmentCommitMismatch(commit.jobID) }

            if try (Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_assets WHERE path = ? AND state = 'ready' AND id <> ?",
                arguments: [commit.finalURL.path(percentEncoded: false), commit.assetID.databaseID]
            ) ?? 0) > 0 {
                throw PersistenceStoreError.readyAssetAlreadyExists(commit.finalURL.path(percentEncoded: false))
            }
            try db.execute(
                sql: """
                UPDATE media_assets
                SET state = 'ready', path = ?, byte_count = ?, pixel_width = ?, pixel_height = ?, frame_count = ?,
                    ready_at = ?, failure_message = NULL
                WHERE id = ? AND kind = 'videoSegment' AND state <> 'ready'
                """,
                arguments: [
                    commit.finalURL.path(percentEncoded: false), max(0, commit.byteCount), commit.canvasWidth,
                    commit.canvasHeight, commit.frameCount, Date().databaseTime, commit.assetID.databaseID,
                ]
            )
            guard db.changesCount == 1 else {
                throw PersistenceStoreError.readyAssetAlreadyExists(commit.finalURL.path(percentEncoded: false))
            }
            for row in frameRows {
                try db.execute(
                    sql: "UPDATE frames SET asset_id = ?, asset_frame_index = ?, asset_pts_value = ?, asset_pts_timescale = ? WHERE id = ?",
                    arguments: [
                        commit.assetID.databaseID, row["ordinal"] as Int, row["pts_value"] as Int64,
                        row["pts_timescale"] as Int32, row["frame_id"] as String,
                    ]
                )
            }
            try db.execute(
                sql: """
                UPDATE segment_jobs
                SET state = 'committed', committed_at = ?, lease_worker_id = NULL, lease_expires_at = NULL, retry_at = NULL
                WHERE id = ?
                """,
                arguments: [Date().databaseTime, commit.jobID.databaseID]
            )
            return frameRows.map { URL(filePath: $0["spool_path"] as String) }
        }
    }

    func failSegmentJob(
        jobID: UUID,
        workerID: UUID,
        message: String,
        retryAt: Date,
        finalByteCount: Int
    ) async throws {
        try await database.pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, lease_worker_id, asset_id FROM segment_jobs WHERE id = ?",
                arguments: [jobID.databaseID]
            ) else { throw PersistenceStoreError.segmentJobNotFound(jobID) }
            let state: String = row["state"]
            guard state == SegmentJobState.leased.rawValue || state == SegmentJobState.published.rawValue else {
                throw PersistenceStoreError.segmentJobNotLeased(jobID)
            }
            guard row["lease_worker_id"] as String? == workerID.databaseID else {
                throw PersistenceStoreError.segmentLeaseOwnedByAnotherWorker(jobID)
            }
            try db.execute(
                sql: """
                UPDATE segment_jobs
                SET state = 'failed', failure_message = ?, retry_at = ?, lease_worker_id = NULL, lease_expires_at = NULL
                WHERE id = ?
                """,
                arguments: [message, retryAt.databaseTime, jobID.databaseID]
            )
            try db.execute(
                sql: """
                UPDATE media_assets
                SET state = 'failed', byte_count = ?, failure_message = ?
                WHERE id = ? AND state <> 'ready'
                """,
                arguments: [max(0, finalByteCount), message, row["asset_id"] as String]
            )
        }
    }

    func requeueSegmentJob(jobID: UUID, workerID: UUID) async throws {
        try await database.pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, lease_worker_id, asset_id FROM segment_jobs WHERE id = ?",
                arguments: [jobID.databaseID]
            ) else { throw PersistenceStoreError.segmentJobNotFound(jobID) }
            let state: String = row["state"]
            guard state == SegmentJobState.leased.rawValue || state == SegmentJobState.published.rawValue else {
                throw PersistenceStoreError.segmentJobNotLeased(jobID)
            }
            guard row["lease_worker_id"] as String? == workerID.databaseID else {
                throw PersistenceStoreError.segmentLeaseOwnedByAnotherWorker(jobID)
            }
            try db.execute(
                sql: """
                UPDATE segment_jobs
                SET state = 'queued', failure_message = NULL, retry_at = NULL,
                    lease_worker_id = NULL, lease_expires_at = NULL
                WHERE id = ?
                """,
                arguments: [jobID.databaseID]
            )
            try db.execute(
                sql: """
                UPDATE media_assets
                SET state = 'writing', failure_message = NULL
                WHERE id = ? AND state <> 'ready'
                """,
                arguments: [row["asset_id"] as String]
            )
        }
    }

    func recoverSegmentJobs(now _: Date) async throws -> [SegmentRecoveryItem] {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE segment_jobs
                SET state = 'queued', lease_worker_id = NULL, lease_expires_at = NULL, retry_at = NULL
                WHERE state IN ('leased', 'failed', 'published')
                  AND session_id IN (SELECT id FROM sessions WHERE state <> 'tombstoned')
                """
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT j.id, j.state, j.lease_worker_id
                FROM segment_jobs j JOIN sessions s ON s.id = j.session_id
                WHERE s.state <> 'tombstoned' AND j.state <> 'committed'
                ORDER BY j.created_at, j.id
                """
            )
            return try rows.compactMap { row in
                let id: String = row["id"]
                guard let manifest = try Self.segmentManifest(jobID: id, db: db),
                      let state = SegmentJobState(rawValue: row["state"])
                else { return nil }
                let workerString: String? = row["lease_worker_id"]
                return SegmentRecoveryItem(
                    manifest: manifest,
                    state: state,
                    workerID: workerString.flatMap(UUID.init(uuidString:))
                )
            }
        }
    }

    func pendingSegmentCleanups() async throws -> [SegmentCleanupManifest] {
        try await database.pool.read { db in
            let jobIDs = try String.fetchAll(
                db,
                sql: """
                SELECT j.id FROM segment_jobs j
                JOIN sessions s ON s.id = j.session_id
                WHERE s.state <> 'tombstoned' AND j.state = 'committed'
                  AND j.cleanup_completed_at IS NULL
                ORDER BY j.committed_at, j.id
                """
            )
            return try jobIDs.compactMap { jobID in
                guard let id = UUID(uuidString: jobID) else { return nil }
                let paths = try String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT f.spool_path
                    FROM segment_job_frames jf JOIN frames f ON f.id = jf.frame_id
                    WHERE jf.job_id = ? ORDER BY f.spool_path
                    """,
                    arguments: [jobID]
                )
                return SegmentCleanupManifest(jobID: id, spoolURLs: paths.map { URL(filePath: $0) })
            }
        }
    }

    func completeSegmentCleanup(_ jobID: UUID) async throws {
        try await database.pool.write { db in
            guard let state = try String.fetchOne(
                db,
                sql: "SELECT state FROM segment_jobs WHERE id = ?",
                arguments: [jobID.databaseID]
            ), state == SegmentJobState.committed.rawValue else {
                throw PersistenceStoreError.segmentJobNotFound(jobID)
            }
            let paths = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT f.spool_path
                FROM segment_job_frames jf JOIN frames f ON f.id = jf.frame_id
                WHERE jf.job_id = ?
                """,
                arguments: [jobID.databaseID]
            )
            try db.execute(
                sql: "UPDATE segment_jobs SET cleanup_completed_at = ? WHERE id = ?",
                arguments: [Date().databaseTime, jobID.databaseID]
            )
            guard !paths.isEmpty else { return }
            let placeholders = Self.placeholders(paths.count)
            try db.execute(
                sql: """
                DELETE FROM media_assets
                WHERE kind = 'spoolImage' AND path IN (\(placeholders))
                  AND NOT EXISTS (SELECT 1 FROM frames f WHERE f.asset_id = media_assets.id)
                """,
                arguments: StatementArguments(paths)
            )
        }
    }
}
