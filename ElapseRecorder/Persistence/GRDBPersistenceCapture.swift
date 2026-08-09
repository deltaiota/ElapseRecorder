import Foundation
import GRDB

nonisolated extension GRDBPersistenceStore {
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
}
