import Foundation
import GRDB

nonisolated extension GRDBPersistenceStore {
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
}
