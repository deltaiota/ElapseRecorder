import Foundation
import GRDB

final nonisolated class GRDBPersistenceStore: Sendable {
    private let database: ElapseDatabase

    init(database: ElapseDatabase) {
        self.database = database
    }

    func openSession(_ session: CaptureSession) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions
                    (id, bundle_identifier, display_name, process_identifier, started_at, ended_at, state)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id.databaseID,
                    session.bundleIdentifier,
                    session.displayName,
                    Int64(session.processIdentifier),
                    session.startedAt.databaseTime,
                    session.endedAt?.databaseTime,
                    session.endedAt == nil ? CaptureSessionDatabaseState.open.rawValue : CaptureSessionDatabaseState.closed.rawValue,
                ]
            )
        }
    }

    func closeSession(_ sessionID: UUID, endedAt: Date) async throws {
        try await database.pool.write { db in
            guard try Self.sessionExists(sessionID, db: db) else {
                throw CaptureEngineError.sessionNotFound(sessionID)
            }
            if try Self.sessionIsEmpty(sessionID, db: db) {
                try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sessionID.databaseID])
            } else {
                try db.execute(
                    sql: "UPDATE sessions SET ended_at = ?, state = 'closed' WHERE id = ?",
                    arguments: [endedAt.databaseTime, sessionID.databaseID]
                )
            }
        }
    }

    func closeOpenSessions(endedAt: Date) async throws -> Int {
        try await database.pool.write { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM sessions WHERE state = 'open' AND started_at < ? ORDER BY started_at, id",
                arguments: [endedAt.databaseTime]
            )
            for id in ids {
                guard let sessionID = UUID(uuidString: id) else { continue }
                if try Self.sessionIsEmpty(sessionID, db: db) {
                    try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
                } else {
                    try db.execute(
                        sql: "UPDATE sessions SET ended_at = ?, state = 'closed' WHERE id = ?",
                        arguments: [endedAt.databaseTime, id]
                    )
                }
            }
            return ids.count
        }
    }

    func deleteSession(_ sessionID: UUID) async throws {
        try await database.pool.write { db in
            guard try Self.sessionExists(sessionID, db: db) else {
                throw CaptureEngineError.sessionNotFound(sessionID)
            }
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sessionID.databaseID])
        }
    }

    func deleteApp(_ bundleIdentifier: String) async throws {
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE bundle_identifier = ? AND state <> 'tombstoned'", arguments: [bundleIdentifier])
        }
    }

    func deleteScreenshots(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await database.pool.write { db in
            let placeholders = Self.placeholders(ids.count)
            let arguments = StatementArguments(ids.map(\.databaseID))
            let directAssetIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM media_assets WHERE id IN (\(placeholders))",
                arguments: arguments
            )
            let frameAssetIDs = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT asset_id FROM frames WHERE id IN (\(placeholders))",
                arguments: arguments
            )
            let cancelledSegmentAssetIDs = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT j.asset_id FROM segment_jobs j
                WHERE j.state <> 'committed' AND j.id IN (
                    SELECT jf.job_id FROM segment_job_frames jf
                    JOIN frames f ON f.id = jf.frame_id
                    WHERE f.id IN (\(placeholders)) OR f.asset_id IN (\(placeholders))
                )
                """,
                arguments: arguments + arguments
            )
            try db.execute(
                sql: """
                DELETE FROM segment_jobs
                WHERE state <> 'committed' AND id IN (
                    SELECT jf.job_id FROM segment_job_frames jf
                    JOIN frames f ON f.id = jf.frame_id
                    WHERE f.id IN (\(placeholders)) OR f.asset_id IN (\(placeholders))
                )
                """,
                arguments: arguments + arguments
            )
            try db.execute(
                sql: "DELETE FROM frames WHERE id IN (\(placeholders))",
                arguments: arguments
            )
            if !directAssetIDs.isEmpty {
                let directPlaceholders = Self.placeholders(directAssetIDs.count)
                try db.execute(
                    sql: "DELETE FROM frames WHERE asset_id IN (\(directPlaceholders))",
                    arguments: StatementArguments(directAssetIDs)
                )
            }
            let affectedAssetIDs = Array(Set(directAssetIDs + frameAssetIDs + cancelledSegmentAssetIDs))
            if !affectedAssetIDs.isEmpty {
                let assetPlaceholders = Self.placeholders(affectedAssetIDs.count)
                try db.execute(
                    sql: "DELETE FROM media_assets WHERE id IN (\(assetPlaceholders)) AND NOT EXISTS (SELECT 1 FROM frames WHERE frames.asset_id = media_assets.id)",
                    arguments: StatementArguments(affectedAssetIDs)
                )
            }
        }
    }

    func screenshotFileIndex() async throws -> [ScreenshotFileReference] {
        try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT a.id, a.path, a.byte_count
                FROM media_assets a JOIN sessions s ON s.id = a.session_id
                WHERE s.state <> 'tombstoned' AND (
                    (a.state = 'ready' AND EXISTS (SELECT 1 FROM frames f WHERE f.asset_id = a.id))
                    OR (a.kind = 'spoolImage' AND a.state = 'ready'
                        AND EXISTS (SELECT 1 FROM frames f WHERE f.spool_path = a.path))
                    OR (a.kind = 'videoSegment' AND a.byte_count > 0
                        AND EXISTS (SELECT 1 FROM segment_jobs j WHERE j.asset_id = a.id))
                )
                ORDER BY a.created_at, a.id
                """
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return ScreenshotFileReference(id: id, path: row["path"], sizeBytes: row["byte_count"])
            }
        }
    }

    func sessionsStarted(before cutoff: Date, bundleIdentifier: String?) async throws -> [CaptureSessionSummary] {
        try await database.pool.read { db in
            var sql = Self.sessionSummarySQL + " WHERE s.state <> 'tombstoned' AND s.started_at < ? AND " + Self.visibleSessionPredicate
            var values: [DatabaseValue] = [cutoff.databaseTime.databaseValue]
            if let bundleIdentifier {
                sql += " AND s.bundle_identifier = ?"
                values.append(bundleIdentifier.databaseValue)
            }
            sql += " ORDER BY s.started_at DESC, s.id DESC"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values)).compactMap(Self.sessionSummary)
        }
    }

    func screenshotPaths(sessionID: UUID) async throws -> [String] {
        try await database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT a.path
                FROM media_assets a JOIN sessions s ON s.id = a.session_id
                WHERE s.state <> 'tombstoned' AND a.session_id = ?
                  AND EXISTS (SELECT 1 FROM frames f WHERE f.asset_id = a.id)
                ORDER BY a.path
                """,
                arguments: [sessionID.databaseID]
            )
        }
    }

    func screenshotPaths(bundleIdentifier: String) async throws -> [String] {
        try await database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT a.path
                FROM media_assets a
                JOIN sessions s ON s.id = a.session_id
                WHERE s.state <> 'tombstoned' AND s.bundle_identifier = ?
                  AND EXISTS (SELECT 1 FROM frames f WHERE f.asset_id = a.id)
                ORDER BY a.path
                """,
                arguments: [bundleIdentifier]
            )
        }
    }

    func endedSessionsOldestFirst() async throws -> [CaptureSessionSummary] {
        try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: Self.sessionSummarySQL + " WHERE s.state = 'closed' ORDER BY s.started_at, s.id"
            ).compactMap(Self.sessionSummary)
        }
    }

    func retentionSnapshot() async throws -> RetentionSnapshot {
        try await database.pool.read { db in
            let ended = try Row.fetchAll(
                db,
                sql: Self.sessionSummarySQL + " WHERE s.state = 'closed' ORDER BY s.started_at, s.id"
            ).compactMap(Self.sessionSummary)
            let activeSize = try Int.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(a.byte_count), 0)
                FROM media_assets a JOIN sessions s ON s.id = a.session_id
                WHERE s.state = 'open' AND (
                    a.state = 'ready' OR (a.kind = 'videoSegment' AND a.byte_count > 0)
                )
                """
            ) ?? 0
            let activeFrames = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM frames f
                JOIN sessions s ON s.id = f.session_id
                JOIN media_assets a ON a.id = f.asset_id AND a.state = 'ready'
                WHERE s.state = 'open'
                """
            ) ?? 0
            return RetentionSnapshot(
                endedSessionsOldestFirst: ended,
                activeSizeBytes: activeSize,
                activeFrameCount: activeFrames
            )
        }
    }

    func prepareSessionDeletion(_ sessionIDs: [UUID]) async throws -> StorageDeletionManifest? {
        guard !sessionIDs.isEmpty else { return nil }
        return try await database.pool.write { db -> StorageDeletionManifest? in
            let placeholders = Self.placeholders(sessionIDs.count)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, bundle_identifier FROM sessions
                WHERE state = 'closed' AND id IN (\(placeholders))
                ORDER BY started_at, id
                """,
                arguments: StatementArguments(sessionIDs.map(\.databaseID))
            )
            let sessions: [StorageDeletionSession] = rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return StorageDeletionSession(id: id, bundleIdentifier: row["bundle_identifier"])
            }
            guard !sessions.isEmpty else { return nil }

            let selectedIDs = sessions.map { $0.id.databaseID }
            let selectedPlaceholders = Self.placeholders(selectedIDs.count)
            let paths = try String.fetchAll(
                db,
                sql: """
                SELECT path FROM media_assets WHERE session_id IN (\(selectedPlaceholders))
                UNION
                SELECT partial_path FROM segment_jobs WHERE session_id IN (\(selectedPlaceholders))
                UNION
                SELECT final_path FROM segment_jobs WHERE session_id IN (\(selectedPlaceholders))
                ORDER BY 1
                """,
                arguments: StatementArguments(selectedIDs + selectedIDs + selectedIDs)
            )
            let tombstoneID = UUID()
            try db.execute(
                sql: "INSERT INTO storage_deletion_tombstones (id, created_at) VALUES (?, ?)",
                arguments: [tombstoneID.databaseID, Date().databaseTime]
            )
            for session in sessions {
                try db.execute(
                    sql: "INSERT INTO storage_deletion_sessions (tombstone_id, session_id) VALUES (?, ?)",
                    arguments: [tombstoneID.databaseID, session.id.databaseID]
                )
            }
            for path in paths {
                try db.execute(
                    sql: "INSERT INTO storage_deletion_files (tombstone_id, path) VALUES (?, ?)",
                    arguments: [tombstoneID.databaseID, path]
                )
            }
            try db.execute(
                sql: "UPDATE sessions SET state = 'tombstoned' WHERE id IN (\(selectedPlaceholders)) AND state = 'closed'",
                arguments: StatementArguments(selectedIDs)
            )
            return StorageDeletionManifest(
                id: tombstoneID,
                sessions: sessions,
                fileURLs: paths.map { URL(filePath: $0) }
            )
        }
    }

    func pendingSessionDeletions() async throws -> [StorageDeletionManifest] {
        try await database.pool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM storage_deletion_tombstones ORDER BY created_at, id"
            )
            return try ids.compactMap { try Self.deletionManifest(id: $0, db: db) }
        }
    }

    func finalizeSessionDeletion(_ tombstoneID: UUID) async throws {
        try await database.pool.write { db in
            let sessionIDs = try String.fetchAll(
                db,
                sql: "SELECT session_id FROM storage_deletion_sessions WHERE tombstone_id = ? ORDER BY session_id",
                arguments: [tombstoneID.databaseID]
            )
            if !sessionIDs.isEmpty {
                try db.execute(
                    sql: "DELETE FROM sessions WHERE state = 'tombstoned' AND id IN (\(Self.placeholders(sessionIDs.count)))",
                    arguments: StatementArguments(sessionIDs)
                )
            }
            try db.execute(
                sql: "DELETE FROM storage_deletion_tombstones WHERE id = ?",
                arguments: [tombstoneID.databaseID]
            )
        }
    }

    func upsertWindow(_ window: MonitoredWindow) async throws {
        try await database.pool.write { db in
            guard try Self.sessionExists(window.sessionID, db: db) else {
                throw CaptureEngineError.sessionNotFound(window.sessionID)
            }
            try db.execute(
                sql: """
                INSERT INTO windows
                    (id, session_id, system_window_id, display_number, label, first_seen_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    label = excluded.label,
                    last_seen_at = excluded.last_seen_at
                """,
                arguments: [
                    window.id.databaseID, window.sessionID.databaseID, window.systemWindowID,
                    window.displayNumber, window.label, window.firstSeenAt.databaseTime, window.lastSeenAt.databaseTime,
                ]
            )
            for observation in window.titleHistory {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO title_observations (id, window_id, title, observed_at) VALUES (?, ?, ?, ?)",
                    arguments: [observation.id.databaseID, window.id.databaseID, observation.title, observation.observedAt.databaseTime]
                )
            }
        }
    }

    func recordScreenshot(_ record: ScreenshotRecord) async throws {
        try await database.pool.write { db in
            try Self.requireSessionAndWindow(sessionID: record.sessionID, windowID: record.windowID, db: db)
            let path = record.fileURL.path(percentEncoded: false)
            let format = CaptureImageFormat(rawValue: record.fileURL.pathExtension.lowercased()) ?? .heic
            try db.execute(
                sql: """
                INSERT INTO media_assets
                    (id, session_id, window_id, kind, state, path, byte_count, pixel_width, pixel_height, frame_count, created_at, ready_at)
                VALUES (?, ?, ?, 'spoolImage', 'ready', ?, ?, ?, ?, 1, ?, ?)
                """,
                arguments: [
                    record.id.databaseID, record.sessionID.databaseID, record.windowID.databaseID, path,
                    max(0, record.fileSizeBytes), max(0, record.pixelWidth), max(0, record.pixelHeight),
                    record.capturedAt.databaseTime, record.capturedAt.databaseTime,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO frames
                    (id, session_id, window_id, asset_id, captured_at, spool_path, image_format, pixel_width, pixel_height,
                     perceptual_hash, request_started_at, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.id.databaseID, record.sessionID.databaseID, record.windowID.databaseID, record.id.databaseID,
                    record.capturedAt.databaseTime, path, format.rawValue, max(0, record.pixelWidth), max(0, record.pixelHeight),
                    Int64(bitPattern: record.perceptualHash), record.capturedAt.databaseTime, record.capturedAt.databaseTime,
                ]
            )
        }
    }

    func recordCaptureUnavailable(_ record: CaptureUnavailableRecord) async throws {
        try await database.pool.write { db in
            guard try Self.sessionExists(record.sessionID, db: db) else {
                throw CaptureEngineError.sessionNotFound(record.sessionID)
            }
            try db.execute(
                sql: """
                INSERT INTO unavailable_spans (id, session_id, started_at, ended_at, reason)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET ended_at = excluded.ended_at, reason = excluded.reason
                """,
                arguments: [
                    record.id.databaseID, record.sessionID.databaseID, record.startedAt.databaseTime,
                    record.endedAt.databaseTime, record.reason.rawValue,
                ]
            )
        }
    }

    func registerSpoolFrame(_ registration: SpoolFrameRegistration) async throws {
        guard registration.spoolURL.pathExtension.lowercased() == registration.format.rawValue else {
            throw PersistenceStoreError.invalidSpoolMetadata(registration.id)
        }
        try await database.pool.write { db in
            try Self.requireSessionAndWindow(sessionID: registration.sessionID, windowID: registration.windowID, db: db)
            let path = registration.spoolURL.path(percentEncoded: false)
            try db.execute(
                sql: """
                INSERT INTO media_assets
                    (id, session_id, window_id, kind, state, path, byte_count, pixel_width, pixel_height, frame_count, created_at)
                VALUES (?, ?, ?, 'spoolImage', 'writing', ?, 0, ?, ?, 1, ?)
                """,
                arguments: [
                    registration.id.databaseID, registration.sessionID.databaseID, registration.windowID.databaseID,
                    path, max(0, registration.pixelWidth), max(0, registration.pixelHeight), registration.completedAt.databaseTime,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO frames
                    (id, session_id, window_id, asset_id, captured_at, spool_path, image_format, pixel_width, pixel_height,
                     perceptual_hash, process_identifier, generation, cycle_sequence, scheduled_offset_nanoseconds,
                     request_started_at, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    registration.id.databaseID, registration.sessionID.databaseID, registration.windowID.databaseID,
                    registration.id.databaseID, registration.completedAt.databaseTime, path, registration.format.rawValue,
                    max(0, registration.pixelWidth), max(0, registration.pixelHeight), Int64(bitPattern: registration.perceptualHash),
                    Int64(registration.processIdentifier), Int64(bitPattern: registration.generation), registration.cycleSequence,
                    registration.scheduledOffsetNanoseconds, registration.requestStartedAt.databaseTime, registration.completedAt.databaseTime,
                ]
            )
        }
    }

    func markSpoolFrameReady(frameID: UUID, byteCount: Int) async throws -> StoredSpoolFrame {
        guard byteCount > 0 else { throw PersistenceStoreError.invalidSpoolMetadata(frameID) }
        return try await database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE media_assets
                SET state = 'ready', byte_count = ?, ready_at = ?, failure_message = NULL
                WHERE id = ? AND kind = 'spoolImage' AND state IN ('writing', 'failed')
                """,
                arguments: [max(0, byteCount), Date().databaseTime, frameID.databaseID]
            )
            guard db.changesCount == 1,
                  let row = try Self.spoolRow(frameID: frameID, requiredState: MediaAssetState.ready.rawValue, db: db),
                  let frame = Self.storedSpoolFrame(row)
            else { throw PersistenceStoreError.frameNotFound(frameID) }
            return frame
        }
    }

    func failSpoolFrame(frameID: UUID, message: String) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE media_assets SET state = 'failed', failure_message = ? WHERE id = ? AND kind = 'spoolImage' AND state <> 'ready'",
                arguments: [message, frameID.databaseID]
            )
            guard db.changesCount == 1 else { throw PersistenceStoreError.frameNotFound(frameID) }
        }
    }

    func recoverSpoolFrames(limit: Int) async throws -> [SpoolFrameRecoveryItem] {
        guard limit > 0 else { return [] }
        return try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: Self.spoolSelectSQL + " WHERE a.kind = 'spoolImage' AND a.state IN ('writing', 'failed') ORDER BY f.session_id, f.window_id, f.cycle_sequence, f.id LIMIT ?",
                arguments: [limit]
            ).compactMap(Self.spoolRecoveryItem)
        }
    }

    func pendingSpoolFrames(limit: Int) async throws -> [StoredSpoolFrame] {
        guard limit > 0 else { return [] }
        return try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: Self.spoolSelectSQL + """
                 WHERE a.kind = 'spoolImage' AND a.state = 'ready'
                  AND f.image_format = 'heic'
                  AND f.generation > 0
                  AND NOT EXISTS (SELECT 1 FROM segment_job_frames jf WHERE jf.frame_id = f.id)
                ORDER BY f.session_id, f.window_id, f.cycle_sequence, f.id LIMIT ?
                """,
                arguments: [limit]
            ).compactMap(Self.storedSpoolFrame)
        }
    }

    func spoolByteCount() async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(a.byte_count), 0)
                FROM media_assets a
                JOIN sessions s ON s.id = a.session_id
                WHERE s.state <> 'tombstoned' AND a.kind = 'spoolImage' AND a.state = 'ready'
                  AND EXISTS (
                      SELECT 1 FROM frames f WHERE f.spool_path = a.path AND f.image_format = 'heic'
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM frames f
                      JOIN segment_job_frames jf ON jf.frame_id = f.id
                      JOIN segment_jobs j ON j.id = jf.job_id AND j.state = 'committed'
                      WHERE f.spool_path = a.path
                  )
                """
            ) ?? 0
        }
    }

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

    func apps() async throws -> [AppCaptureSummary] {
        try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                WITH visible_sessions AS (
                    SELECT s.* FROM sessions s
                    WHERE s.state <> 'tombstoned' AND (
                        EXISTS (SELECT 1 FROM windows w WHERE w.session_id = s.id)
                        OR EXISTS (SELECT 1 FROM frames f WHERE f.session_id = s.id)
                        OR EXISTS (SELECT 1 FROM unavailable_spans u WHERE u.session_id = s.id)
                    )
                ), session_stats AS (
                    SELECT s.id, s.bundle_identifier, s.display_name, s.started_at, s.ended_at,
                           MAX(f.captured_at) AS last_frame,
                           COUNT(f.id) AS frame_count
                    FROM visible_sessions s LEFT JOIN frames f ON f.session_id = s.id
                        AND EXISTS (SELECT 1 FROM media_assets fa WHERE fa.id = f.asset_id AND fa.state = 'ready')
                    GROUP BY s.id
                ), asset_stats AS (
                    SELECT s.bundle_identifier, COALESCE(SUM(a.byte_count), 0) AS size_bytes
                    FROM visible_sessions s LEFT JOIN media_assets a ON a.session_id = s.id
                        AND (a.state = 'ready' OR (a.kind = 'videoSegment' AND a.byte_count > 0))
                    GROUP BY s.bundle_identifier
                )
                SELECT ss.bundle_identifier,
                       (SELECT display_name FROM session_stats latest WHERE latest.bundle_identifier = ss.bundle_identifier
                        ORDER BY latest.started_at DESC, latest.id DESC LIMIT 1) AS display_name,
                       COUNT(*) AS session_count,
                       SUM(ss.frame_count) AS screenshot_count,
                       MAX(ss.last_frame) AS last_captured_at,
                       COALESCE(ast.size_bytes, 0) AS size_bytes,
                       SUM(MAX(0, COALESCE(ss.ended_at, ss.last_frame, ss.started_at) - ss.started_at)) AS total_duration
                FROM session_stats ss
                LEFT JOIN asset_stats ast ON ast.bundle_identifier = ss.bundle_identifier
                GROUP BY ss.bundle_identifier
                ORDER BY (last_captured_at IS NULL), last_captured_at DESC, display_name, ss.bundle_identifier
                """
            ).map { row in
                let last: Double? = row["last_captured_at"]
                return AppCaptureSummary(
                    bundleIdentifier: row["bundle_identifier"],
                    displayName: row["display_name"],
                    sessionCount: row["session_count"],
                    screenshotCount: row["screenshot_count"],
                    lastCapturedAt: last.map(Date.init(databaseTime:)),
                    sizeBytes: row["size_bytes"],
                    totalActiveDuration: row["total_duration"]
                )
            }
        }
    }

    func sessions(bundleIdentifier: String) async throws -> [CaptureSessionSummary] {
        try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: Self.sessionSummarySQL + " WHERE s.state <> 'tombstoned' AND s.bundle_identifier = ? AND " + Self.visibleSessionPredicate + " ORDER BY s.started_at DESC, s.id DESC",
                arguments: [bundleIdentifier]
            ).compactMap(Self.sessionSummary)
        }
    }

    func windows(sessionID: UUID) async throws -> [WindowCaptureSummary] {
        try await database.pool.read { db in
            guard try Self.sessionExists(sessionID, db: db) else {
                throw CaptureEngineError.sessionNotFound(sessionID)
            }
            return try Row.fetchAll(
                db,
                sql: """
                SELECT w.*, COUNT(a.id) AS screenshot_count
                FROM windows w
                LEFT JOIN frames f ON f.window_id = w.id
                LEFT JOIN media_assets a ON a.id = f.asset_id AND a.state = 'ready'
                WHERE w.session_id = ? GROUP BY w.id
                ORDER BY w.display_number, w.id
                """,
                arguments: [sessionID.databaseID]
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return WindowCaptureSummary(
                    id: id,
                    displayNumber: row["display_number"],
                    label: row["label"],
                    firstSeenAt: Date(databaseTime: row["first_seen_at"]),
                    lastSeenAt: Date(databaseTime: row["last_seen_at"]),
                    screenshotCount: row["screenshot_count"]
                )
            }
        }
    }

    func screenshotsForSession(_ sessionID: UUID) async throws -> [ScreenshotRecord] {
        try await database.pool.read { db in
            guard try Self.sessionExists(sessionID, db: db) else {
                throw CaptureEngineError.sessionNotFound(sessionID)
            }
            return try Self.fetchFrames(db: db, where: "f.session_id = ?", arguments: [sessionID.databaseID])
        }
    }

    func screenshotsForWindow(_ windowID: UUID) async throws -> [ScreenshotRecord] {
        try await database.pool.read { db in
            try Self.fetchFrames(db: db, where: "f.window_id = ?", arguments: [windowID.databaseID])
        }
    }

    func screenshotsForApp(_ bundleIdentifier: String) async throws -> [ScreenshotRecord] {
        try await database.pool.read { db in
            try Self.fetchFrames(db: db, where: "s.bundle_identifier = ?", arguments: [bundleIdentifier])
        }
    }

    func framePage(query: FrameQuery, after: FrameCursor?, limit: Int) async throws -> FramePage {
        guard limit > 0 else { return try FramePage(frames: [], nextCursor: nil, totalCount: await frameCount(query: query)) }
        return try await database.pool.read { db in
            let descriptor = Self.frameDescriptor(query, after: after)
            let totalCount = try Self.frameCount(query: query, db: db)
            let rows = try Row.fetchAll(
                db,
                sql: Self.frameSelectSQL + " WHERE " + descriptor.whereSQL + " ORDER BY f.captured_at, f.id LIMIT ?",
                arguments: descriptor.arguments + StatementArguments([limit + 1])
            )
            let mapped = rows.compactMap(Self.screenshotRecord)
            let frames = Array(mapped.prefix(limit))
            return FramePage(
                frames: frames,
                nextCursor: mapped.count > limit ? frames.last.map(FrameCursor.init(frame:)) : nil,
                totalCount: totalCount
            )
        }
    }

    func frameQuerySnapshot(_ query: FrameQuery) async throws -> FrameQuerySnapshot {
        try await database.pool.read { db in
            let descriptor = Self.frameDescriptor(query, after: nil)
            let count = try Self.frameCount(query: query, db: db)
            guard count > 0,
                  let row = try Row.fetchOne(
                      db,
                      sql: """
                      SELECT f.id, f.captured_at FROM frames f
                      JOIN sessions s ON s.id = f.session_id AND s.state <> 'tombstoned'
                      JOIN media_assets a ON a.id = f.asset_id AND a.state = 'ready'
                      WHERE \(descriptor.whereSQL)
                      ORDER BY f.captured_at DESC, f.id DESC LIMIT 1
                      """,
                      arguments: descriptor.arguments
                  ),
                  let id = UUID(uuidString: row["id"])
            else {
                return FrameQuerySnapshot(selection: .ids([]), count: 0)
            }
            let terminal = FrameCursor(capturedAt: Date(databaseTime: row["captured_at"]), id: id)
            let frozen = FrameQuery(scope: query.scope, capturedAt: query.capturedAt, through: terminal)
            return FrameQuerySnapshot(selection: .query(frozen), count: count)
        }
    }

    func frameCount(query: FrameQuery) async throws -> Int {
        try await database.pool.read { db in try Self.frameCount(query: query, db: db) }
    }

    func framesByID(_ ids: [UUID]) async throws -> [ScreenshotRecord] {
        guard !ids.isEmpty else { return [] }
        return try await database.pool.read { db in
            let placeholders = Self.placeholders(ids.count)
            let rows = try Row.fetchAll(
                db,
                sql: Self.frameSelectSQL + " WHERE f.id IN (\(placeholders))",
                arguments: StatementArguments(ids.map(\.databaseID))
            )
            let records = rows.compactMap(Self.screenshotRecord)
            let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }
        }
    }

    func timelineForSession(_ sessionID: UUID) async throws -> [CaptureTimelineEntry] {
        async let frames = screenshotsForSession(sessionID)
        async let spans = unavailableRecords(where: "u.session_id = ?", arguments: [sessionID.databaseID])
        return try await Self.timelineEntries(screenshots: frames, unavailableRecords: spans)
    }

    func timelineForWindow(sessionID: UUID, windowID: UUID) async throws -> [CaptureTimelineEntry] {
        async let frames = screenshotsForWindow(windowID)
        async let spans = unavailableRecords(where: "u.session_id = ?", arguments: [sessionID.databaseID])
        return try await Self.timelineEntries(screenshots: frames, unavailableRecords: spans)
    }

    func timelineForApp(_ bundleIdentifier: String) async throws -> [CaptureTimelineEntry] {
        async let frames = screenshotsForApp(bundleIdentifier)
        async let spans = unavailableRecords(
            where: "s.bundle_identifier = ?",
            arguments: [bundleIdentifier],
            joinsSessions: true
        )
        return try await Self.timelineEntries(screenshots: frames, unavailableRecords: spans)
    }

    func sessionTimeline(_ sessionID: UUID) async throws -> SessionTimeline {
        try await database.pool.read { db in
            guard let session = try Row.fetchOne(
                db,
                sql: "SELECT started_at, ended_at FROM sessions WHERE id = ? AND state <> 'tombstoned'",
                arguments: [sessionID.databaseID]
            ) else { throw CaptureEngineError.sessionNotFound(sessionID) }
            let windows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM windows WHERE session_id = ? ORDER BY display_number, id",
                arguments: [sessionID.databaseID]
            )
            let lanes = try windows.compactMap { row -> WindowLane? in
                guard let windowID = UUID(uuidString: row["id"] as String) else { return nil }
                let screenshotTimes = try Double.fetchAll(
                    db,
                    sql: """
                    SELECT f.captured_at FROM frames f JOIN media_assets a ON a.id = f.asset_id
                    WHERE f.window_id = ? AND a.state = 'ready' ORDER BY f.captured_at, f.id
                    """,
                    arguments: [windowID.databaseID]
                ).map(Date.init(databaseTime:))
                let observations = try Row.fetchAll(
                    db,
                    sql: "SELECT id, title, observed_at FROM title_observations WHERE window_id = ? ORDER BY observed_at, id",
                    arguments: [windowID.databaseID]
                ).compactMap(Self.titleObservation)
                let bornAt = Date(databaseTime: row["first_seen_at"])
                let diedAt = max(bornAt, Date(databaseTime: row["last_seen_at"]))
                return WindowLane(
                    windowID: windowID,
                    displayNumber: row["display_number"],
                    systemWindowID: row["system_window_id"],
                    bornAt: bornAt,
                    diedAt: diedAt,
                    segments: Self.titleSegments(
                        observations: observations,
                        fallbackID: windowID,
                        fallbackTitle: row["label"],
                        bornAt: bornAt,
                        diedAt: diedAt,
                        screenshotTimes: screenshotTimes
                    ),
                    screenshotCount: screenshotTimes.count
                )
            }
            let unavailableSpans = try Row.fetchAll(
                db,
                sql: "SELECT started_at, ended_at FROM unavailable_spans WHERE session_id = ? ORDER BY started_at, id",
                arguments: [sessionID.databaseID]
            ).map { TimeSpan(startedAt: Date(databaseTime: $0["started_at"]), endedAt: Date(databaseTime: $0["ended_at"])) }
            let ended: Double? = session["ended_at"]
            return SessionTimeline(
                sessionID: sessionID,
                startedAt: Date(databaseTime: session["started_at"]),
                endedAt: ended.map(Date.init(databaseTime:)),
                lanes: lanes,
                unavailableSpans: unavailableSpans
            )
        }
    }

    private func unavailableRecords(
        where predicate: String,
        arguments: StatementArguments,
        joinsSessions _: Bool = false
    ) async throws -> [CaptureUnavailableRecord] {
        try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT u.* FROM unavailable_spans u JOIN sessions s ON s.id = u.session_id WHERE s.state <> 'tombstoned' AND \(predicate) ORDER BY u.started_at, u.id",
                arguments: arguments
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let sessionID = UUID(uuidString: row["session_id"]),
                      let reason = CaptureUnavailableReason(rawValue: row["reason"])
                else { return nil }
                return CaptureUnavailableRecord(
                    id: id,
                    sessionID: sessionID,
                    startedAt: Date(databaseTime: row["started_at"]),
                    endedAt: Date(databaseTime: row["ended_at"]),
                    reason: reason
                )
            }
        }
    }

    private static func deletionManifest(id: String, db: Database) throws -> StorageDeletionManifest? {
        guard let tombstoneID = UUID(uuidString: id),
              try Bool.fetchOne(
                  db,
                  sql: "SELECT EXISTS(SELECT 1 FROM storage_deletion_tombstones WHERE id = ?)",
                  arguments: [id]
              ) == true
        else { return nil }
        let sessions = try Row.fetchAll(
            db,
            sql: """
            SELECT s.id, s.bundle_identifier
            FROM storage_deletion_sessions ds JOIN sessions s ON s.id = ds.session_id
            WHERE ds.tombstone_id = ? ORDER BY s.started_at, s.id
            """,
            arguments: [id]
        ).compactMap { row -> StorageDeletionSession? in
            guard let sessionID = UUID(uuidString: row["id"]) else { return nil }
            return StorageDeletionSession(id: sessionID, bundleIdentifier: row["bundle_identifier"])
        }
        let paths = try String.fetchAll(
            db,
            sql: "SELECT path FROM storage_deletion_files WHERE tombstone_id = ? ORDER BY path",
            arguments: [id]
        )
        return StorageDeletionManifest(
            id: tombstoneID,
            sessions: sessions,
            fileURLs: paths.map { URL(filePath: $0) }
        )
    }

    private static let frameSelectSQL = """
    SELECT f.*, s.bundle_identifier,
           a.kind AS asset_kind, a.state AS asset_state, a.path AS asset_path,
           a.byte_count AS asset_byte_count, a.frame_count AS asset_frame_count
    FROM frames f
    JOIN sessions s ON s.id = f.session_id AND s.state <> 'tombstoned'
    JOIN media_assets a ON a.id = f.asset_id AND a.state = 'ready'
    """

    private static let spoolSelectSQL = """
    SELECT f.*, s.bundle_identifier,
           a.state AS asset_state, a.byte_count AS asset_byte_count
    FROM frames f
    JOIN sessions s ON s.id = f.session_id AND s.state <> 'tombstoned'
    JOIN media_assets a ON a.id = f.asset_id
    """

    private static let visibleSessionPredicate = """
    (EXISTS (SELECT 1 FROM windows w WHERE w.session_id = s.id)
     OR EXISTS (SELECT 1 FROM frames f WHERE f.session_id = s.id)
     OR EXISTS (SELECT 1 FROM unavailable_spans u WHERE u.session_id = s.id))
    """

    private static let sessionSummarySQL = """
    SELECT s.*,
           (SELECT COUNT(*) FROM windows w WHERE w.session_id = s.id) AS window_count,
           (SELECT COUNT(*) FROM frames f JOIN media_assets a ON a.id = f.asset_id
            WHERE f.session_id = s.id AND a.state = 'ready') AS screenshot_count,
           (SELECT COALESCE(SUM(a.byte_count), 0) FROM media_assets a
            WHERE a.session_id = s.id
              AND (a.state = 'ready' OR (a.kind = 'videoSegment' AND a.byte_count > 0))) AS size_bytes,
           (SELECT COUNT(*) FROM frames f JOIN media_assets a ON a.id = f.asset_id
            WHERE f.session_id = s.id AND a.kind = 'videoSegment' AND a.state = 'ready') AS compacted_count
    FROM sessions s
    """

    private static func fetchFrames(
        db: Database,
        where predicate: String,
        arguments: StatementArguments
    ) throws -> [ScreenshotRecord] {
        try Row.fetchAll(
            db,
            sql: frameSelectSQL + " WHERE \(predicate) ORDER BY f.captured_at, f.id",
            arguments: arguments
        ).compactMap(screenshotRecord)
    }

    private static func screenshotRecord(_ row: Row) -> ScreenshotRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let sessionID = UUID(uuidString: row["session_id"]),
              let windowID = UUID(uuidString: row["window_id"])
        else { return nil }
        let kind: String = row["asset_kind"]
        let assetBytes: Int = row["asset_byte_count"]
        let assetFrameCount: Int = max(1, row["asset_frame_count"])
        let index: Int? = row["asset_frame_index"]
        let ptsValue: Int64? = row["asset_pts_value"]
        let ptsTimescale: Int32? = row["asset_pts_timescale"]
        let apportionedBytes: Int
        if kind == MediaAssetKind.videoSegment.rawValue, let index {
            apportionedBytes = assetBytes / assetFrameCount + (index < assetBytes % assetFrameCount ? 1 : 0)
        } else {
            apportionedBytes = assetBytes
        }
        let hash: Int64 = row["perceptual_hash"]
        return ScreenshotRecord(
            id: id,
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(databaseTime: row["captured_at"]),
            fileURL: URL(filePath: row["spool_path"] as String),
            fileSizeBytes: apportionedBytes,
            pixelWidth: row["pixel_width"],
            pixelHeight: row["pixel_height"],
            perceptualHash: UInt64(bitPattern: hash),
            videoURL: kind == MediaAssetKind.videoSegment.rawValue ? URL(filePath: row["asset_path"] as String) : nil,
            videoFrameIndex: kind == MediaAssetKind.videoSegment.rawValue ? index : nil,
            videoPTSValue: kind == MediaAssetKind.videoSegment.rawValue ? ptsValue : nil,
            videoPTSTimescale: kind == MediaAssetKind.videoSegment.rawValue ? ptsTimescale : nil
        )
    }

    private static func sessionSummary(_ row: Row) -> CaptureSessionSummary? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let ended: Double? = row["ended_at"]
        return CaptureSessionSummary(
            id: id,
            bundleIdentifier: row["bundle_identifier"],
            displayName: row["display_name"],
            startedAt: Date(databaseTime: row["started_at"]),
            endedAt: ended.map(Date.init(databaseTime:)),
            windowCount: row["window_count"],
            screenshotCount: row["screenshot_count"],
            sizeBytes: row["size_bytes"],
            compactedScreenshotCount: row["compacted_count"]
        )
    }

    private static func spoolRow(frameID: UUID, requiredState: String, db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: spoolSelectSQL + " WHERE f.id = ? AND a.state = ?",
            arguments: [frameID.databaseID, requiredState]
        )
    }

    private static func spoolRegistration(_ row: Row) -> SpoolFrameRegistration? {
        guard let id = UUID(uuidString: row["id"]),
              let sessionID = UUID(uuidString: row["session_id"]),
              let windowID = UUID(uuidString: row["window_id"]),
              let format = CaptureImageFormat(rawValue: row["image_format"])
        else { return nil }
        let generation: Int64 = row["generation"]
        let hash: Int64 = row["perceptual_hash"]
        return SpoolFrameRegistration(
            id: id,
            sessionID: sessionID,
            windowID: windowID,
            bundleIdentifier: row["bundle_identifier"],
            processIdentifier: pid_t(row["process_identifier"] as Int64),
            generation: UInt64(bitPattern: generation),
            cycleSequence: row["cycle_sequence"],
            scheduledOffsetNanoseconds: row["scheduled_offset_nanoseconds"],
            requestStartedAt: Date(databaseTime: row["request_started_at"]),
            completedAt: Date(databaseTime: row["completed_at"]),
            spoolURL: URL(filePath: row["spool_path"] as String),
            format: format,
            pixelWidth: row["pixel_width"],
            pixelHeight: row["pixel_height"],
            perceptualHash: UInt64(bitPattern: hash)
        )
    }

    private static func storedSpoolFrame(_ row: Row) -> StoredSpoolFrame? {
        guard let registration = spoolRegistration(row) else { return nil }
        return StoredSpoolFrame(registration: registration, byteCount: row["asset_byte_count"])
    }

    private static func spoolRecoveryItem(_ row: Row) -> SpoolFrameRecoveryItem? {
        guard let registration = spoolRegistration(row),
              let assetState = MediaAssetState(rawValue: row["asset_state"])
        else { return nil }
        let state: SpoolFrameState
        switch assetState {
        case .writing: state = .registered
        case .ready: state = .ready
        case .failed: state = .failed
        }
        let bytes: Int = row["asset_byte_count"]
        return SpoolFrameRecoveryItem(registration: registration, state: state, byteCount: bytes > 0 ? bytes : nil)
    }

    private static func segmentManifest(jobID: String, db: Database) throws -> SegmentJobManifest? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT j.*, s.bundle_identifier, s.process_identifier
            FROM segment_jobs j JOIN sessions s ON s.id = j.session_id
            WHERE j.id = ?
            """,
            arguments: [jobID]
        ),
            let id = UUID(uuidString: jobID),
            let assetID = UUID(uuidString: row["asset_id"]),
            let sessionID = UUID(uuidString: row["session_id"]),
            let windowID = UUID(uuidString: row["window_id"])
        else { return nil }
        let frameRows = try Row.fetchAll(
            db,
            sql: """
            SELECT jf.frame_id, jf.pts_value, jf.pts_timescale, f.spool_path, f.generation
            FROM segment_job_frames jf JOIN frames f ON f.id = jf.frame_id
            WHERE jf.job_id = ? ORDER BY jf.ordinal
            """,
            arguments: [jobID]
        )
        let generationBits: Int64 = frameRows.first?["generation"] ?? 0
        let frames = frameRows.compactMap { frame -> SegmentFrameInput? in
            guard let frameID = UUID(uuidString: frame["frame_id"]) else { return nil }
            return SegmentFrameInput(
                frameID: frameID,
                spoolURL: URL(filePath: frame["spool_path"] as String),
                ptsValue: frame["pts_value"],
                ptsTimescale: frame["pts_timescale"]
            )
        }
        return SegmentJobManifest(
            jobID: id,
            assetID: assetID,
            handle: RecordingSessionHandle(
                sessionID: sessionID,
                bundleIdentifier: row["bundle_identifier"],
                processIdentifier: pid_t(row["process_identifier"] as Int64),
                generation: UInt64(bitPattern: generationBits)
            ),
            windowID: windowID,
            partialURL: URL(filePath: row["partial_path"] as String),
            finalURL: URL(filePath: row["final_path"] as String),
            canvasWidth: row["canvas_width"],
            canvasHeight: row["canvas_height"],
            frames: frames,
            createdAt: Date(databaseTime: row["created_at"])
        )
    }

    private struct FrameDescriptor {
        var whereSQL: String
        var arguments: StatementArguments
    }

    private static func frameDescriptor(_ query: FrameQuery, after: FrameCursor?) -> FrameDescriptor {
        var predicates: [String] = []
        var values: [DatabaseValue] = []
        switch query.scope {
        case let .app(bundleIdentifier):
            predicates.append("s.bundle_identifier = ?")
            values.append(bundleIdentifier.databaseValue)
        case let .session(id):
            predicates.append("f.session_id = ?")
            values.append(id.databaseID.databaseValue)
        case let .window(sessionID, windowID):
            predicates.append("f.session_id = ? AND f.window_id = ?")
            values.append(sessionID.databaseID.databaseValue)
            values.append(windowID.databaseID.databaseValue)
        }
        if let range = query.capturedAt {
            predicates.append("f.captured_at >= ? AND f.captured_at <= ?")
            values.append(range.lowerBound.databaseTime.databaseValue)
            values.append(range.upperBound.databaseTime.databaseValue)
        }
        if let through = query.through {
            predicates.append("(f.captured_at < ? OR (f.captured_at = ? AND f.id <= ?))")
            values.append(through.capturedAt.databaseTime.databaseValue)
            values.append(through.capturedAt.databaseTime.databaseValue)
            values.append(through.id.databaseID.databaseValue)
        }
        if let after {
            predicates.append("(f.captured_at > ? OR (f.captured_at = ? AND f.id > ?))")
            values.append(after.capturedAt.databaseTime.databaseValue)
            values.append(after.capturedAt.databaseTime.databaseValue)
            values.append(after.id.databaseID.databaseValue)
        }
        return FrameDescriptor(whereSQL: predicates.joined(separator: " AND "), arguments: StatementArguments(values))
    }

    private static func frameCount(query: FrameQuery, db: Database) throws -> Int {
        let descriptor = frameDescriptor(query, after: nil)
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM frames f
            JOIN sessions s ON s.id = f.session_id AND s.state <> 'tombstoned'
            JOIN media_assets a ON a.id = f.asset_id AND a.state = 'ready'
            WHERE \(descriptor.whereSQL)
            """,
            arguments: descriptor.arguments
        ) ?? 0
    }

    private static func sessionExists(_ id: UUID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ? AND state <> 'tombstoned')", arguments: [id.databaseID]) ?? false
    }

    private static func sessionIsEmpty(_ id: UUID, db: Database) throws -> Bool {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
                EXISTS(SELECT 1 FROM windows WHERE session_id = ?) AS has_windows,
                EXISTS(SELECT 1 FROM frames WHERE session_id = ?) AS has_frames,
                EXISTS(SELECT 1 FROM unavailable_spans WHERE session_id = ?) AS has_spans
            """,
            arguments: [id.databaseID, id.databaseID, id.databaseID]
        )!
        return !(row["has_windows"] as Bool) && !(row["has_frames"] as Bool) && !(row["has_spans"] as Bool)
    }

    private static func requireSessionAndWindow(sessionID: UUID, windowID: UUID, db: Database) throws {
        guard try sessionExists(sessionID, db: db) else { throw CaptureEngineError.sessionNotFound(sessionID) }
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM windows WHERE id = ? AND session_id = ?)",
            arguments: [windowID.databaseID, sessionID.databaseID]
        ) ?? false else { throw PersistenceStoreError.windowNotFound(windowID) }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private struct TitleObservation {
        var id: UUID
        var title: String?
        var observedAt: Date
    }

    private static func titleObservation(_ row: Row) -> TitleObservation? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        return TitleObservation(id: id, title: row["title"], observedAt: Date(databaseTime: row["observed_at"]))
    }

    private static func titleSegments(
        observations: [TitleObservation],
        fallbackID: UUID,
        fallbackTitle: String?,
        bornAt: Date,
        diedAt: Date,
        screenshotTimes: [Date]
    ) -> [WindowTitleSegment] {
        guard !observations.isEmpty else {
            return [WindowTitleSegment(id: fallbackID, title: fallbackTitle, startedAt: bornAt, endedAt: diedAt, screenshotCount: screenshotTimes.count)]
        }
        return observations.enumerated().map { index, observation in
            let isLast = index + 1 == observations.count
            let startedAt = index == 0 ? bornAt : observation.observedAt
            let endedAt = isLast ? diedAt : observations[index + 1].observedAt
            let count = screenshotTimes.filter { $0 >= startedAt && (isLast ? $0 <= endedAt : $0 < endedAt) }.count
            return WindowTitleSegment(
                id: observation.id,
                title: observation.title,
                startedAt: startedAt,
                endedAt: max(startedAt, endedAt),
                screenshotCount: count
            )
        }
    }

    private static func timelineEntries(
        screenshots: [ScreenshotRecord],
        unavailableRecords: [CaptureUnavailableRecord]
    ) -> [CaptureTimelineEntry] {
        (screenshots.map(CaptureTimelineEntry.screenshot) + unavailableRecords.map(CaptureTimelineEntry.unavailable))
            .sorted { $0.occurredAt < $1.occurredAt }
    }
}

nonisolated extension PersistenceClient {
    static func live(databaseURL: URL? = nil) -> Self {
        do {
            let url: URL
            if let databaseURL {
                url = databaseURL
            } else {
                url = try FileStoragePaths.databaseURL()
            }
            return try live(database: ElapseDatabase(url: url))
        } catch {
            return unavailable
        }
    }

    static func live(database: ElapseDatabase) -> Self {
        let store = GRDBPersistenceStore(database: database)
        return Self(
            openSession: store.openSession,
            closeSession: store.closeSession,
            closeOpenSessions: store.closeOpenSessions,
            deleteSession: store.deleteSession,
            deleteApp: store.deleteApp,
            deleteScreenshots: store.deleteScreenshots,
            screenshotFileIndex: store.screenshotFileIndex,
            sessionsStartedBefore: store.sessionsStarted,
            screenshotPathsForSession: store.screenshotPaths,
            screenshotPathsForApp: store.screenshotPaths,
            endedSessionsOldestFirst: store.endedSessionsOldestFirst,
            retentionSnapshot: store.retentionSnapshot,
            prepareSessionDeletion: store.prepareSessionDeletion,
            pendingSessionDeletions: store.pendingSessionDeletions,
            finalizeSessionDeletion: store.finalizeSessionDeletion,
            upsertWindow: store.upsertWindow,
            recordScreenshot: store.recordScreenshot,
            recordCaptureUnavailable: store.recordCaptureUnavailable,
            registerSpoolFrame: store.registerSpoolFrame,
            markSpoolFrameReady: store.markSpoolFrameReady,
            failSpoolFrame: store.failSpoolFrame,
            recoverSpoolFrames: store.recoverSpoolFrames,
            pendingSpoolFrames: store.pendingSpoolFrames,
            spoolByteCount: store.spoolByteCount,
            createSegmentJob: store.createSegmentJob,
            leaseSegmentJob: store.leaseSegmentJob,
            markSegmentJobPublished: store.markSegmentJobPublished,
            commitSegmentJob: store.commitSegmentJob,
            failSegmentJob: store.failSegmentJob,
            recoverSegmentJobs: store.recoverSegmentJobs,
            pendingSegmentCleanups: store.pendingSegmentCleanups,
            completeSegmentCleanup: store.completeSegmentCleanup,
            apps: store.apps,
            sessions: store.sessions,
            windows: store.windows,
            screenshotsForSession: store.screenshotsForSession,
            screenshotsForWindow: store.screenshotsForWindow,
            screenshotsForApp: store.screenshotsForApp,
            framePage: store.framePage,
            frameQuerySnapshot: store.frameQuerySnapshot,
            frameCount: store.frameCount,
            framesByID: store.framesByID,
            timelineForSession: store.timelineForSession,
            timelineForWindow: store.timelineForWindow,
            timelineForApp: store.timelineForApp,
            sessionTimeline: store.sessionTimeline
        )
    }

    static let unavailable = Self(
        openSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        closeSession: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        closeOpenSessions: { _ in throw CaptureEngineError.persistenceUnavailable },
        deleteSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        deleteApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        deleteScreenshots: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotFileIndex: { throw CaptureEngineError.persistenceUnavailable },
        sessionsStartedBefore: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotPathsForSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotPathsForApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        endedSessionsOldestFirst: { throw CaptureEngineError.persistenceUnavailable },
        retentionSnapshot: { throw CaptureEngineError.persistenceUnavailable },
        prepareSessionDeletion: { _ in throw CaptureEngineError.persistenceUnavailable },
        pendingSessionDeletions: { throw CaptureEngineError.persistenceUnavailable },
        finalizeSessionDeletion: { _ in throw CaptureEngineError.persistenceUnavailable },
        upsertWindow: { _ in throw CaptureEngineError.persistenceUnavailable },
        recordScreenshot: { _ in throw CaptureEngineError.persistenceUnavailable },
        recordCaptureUnavailable: { _ in throw CaptureEngineError.persistenceUnavailable },
        registerSpoolFrame: { _ in throw CaptureEngineError.persistenceUnavailable },
        markSpoolFrameReady: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        failSpoolFrame: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        recoverSpoolFrames: { _ in throw CaptureEngineError.persistenceUnavailable },
        pendingSpoolFrames: { _ in throw CaptureEngineError.persistenceUnavailable },
        spoolByteCount: { throw CaptureEngineError.persistenceUnavailable },
        createSegmentJob: { _ in throw CaptureEngineError.persistenceUnavailable },
        leaseSegmentJob: { _, _, _ in throw CaptureEngineError.persistenceUnavailable },
        markSegmentJobPublished: { _ in throw CaptureEngineError.persistenceUnavailable },
        commitSegmentJob: { _ in throw CaptureEngineError.persistenceUnavailable },
        failSegmentJob: { _, _, _, _, _ in throw CaptureEngineError.persistenceUnavailable },
        recoverSegmentJobs: { _ in throw CaptureEngineError.persistenceUnavailable },
        pendingSegmentCleanups: { throw CaptureEngineError.persistenceUnavailable },
        completeSegmentCleanup: { _ in throw CaptureEngineError.persistenceUnavailable },
        apps: { throw CaptureEngineError.persistenceUnavailable },
        sessions: { _ in throw CaptureEngineError.persistenceUnavailable },
        windows: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForWindow: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        framePage: { _, _, _ in throw CaptureEngineError.persistenceUnavailable },
        frameQuerySnapshot: { _ in throw CaptureEngineError.persistenceUnavailable },
        frameCount: { _ in throw CaptureEngineError.persistenceUnavailable },
        framesByID: { _ in throw CaptureEngineError.persistenceUnavailable },
        timelineForSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        timelineForWindow: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        timelineForApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        sessionTimeline: { _ in throw CaptureEngineError.persistenceUnavailable }
    )
}

private nonisolated extension UUID {
    var databaseID: String {
        uuidString
    }
}

private nonisolated extension Date {
    var databaseTime: TimeInterval {
        timeIntervalSince1970
    }

    init(databaseTime: TimeInterval) {
        self.init(timeIntervalSince1970: databaseTime)
    }
}
