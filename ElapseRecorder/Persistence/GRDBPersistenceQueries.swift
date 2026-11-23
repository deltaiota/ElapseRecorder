import Foundation
import GRDB

nonisolated extension GRDBPersistenceStore {
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
                           (SELECT f.captured_at FROM frames f
                            JOIN media_assets a ON a.id = f.asset_id AND a.state = 'ready'
                            WHERE f.session_id = s.id ORDER BY f.captured_at DESC, f.id DESC LIMIT 1) AS last_frame,
                           (SELECT COUNT(*) FROM media_assets a JOIN frames f ON f.asset_id = a.id
                            WHERE a.session_id = s.id AND a.state = 'ready') AS frame_count
                    FROM visible_sessions s
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
                        fallback: .init(
                            id: windowID,
                            title: row["label"],
                            bornAt: bornAt,
                            diedAt: diedAt
                        ),
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
}
