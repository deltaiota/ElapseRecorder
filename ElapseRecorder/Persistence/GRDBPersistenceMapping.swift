import Foundation
import GRDB

nonisolated extension GRDBPersistenceStore {
    static func deletionManifest(id: String, db: Database) throws -> StorageDeletionManifest? {
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

    static let frameSelectSQL = """
    SELECT f.*, s.bundle_identifier,
           a.kind AS asset_kind, a.state AS asset_state, a.path AS asset_path,
           a.byte_count AS asset_byte_count, a.frame_count AS asset_frame_count
    FROM frames f
    JOIN sessions s ON s.id = f.session_id AND s.state <> 'tombstoned'
    JOIN media_assets a ON a.id = f.asset_id AND a.state = 'ready'
    """

    static let spoolSelectSQL = """
    SELECT f.*, s.bundle_identifier,
           a.state AS asset_state, a.byte_count AS asset_byte_count
    FROM frames f
    JOIN sessions s ON s.id = f.session_id AND s.state <> 'tombstoned'
    JOIN media_assets a ON a.id = f.asset_id
    """

    static let visibleSessionPredicate = """
    (EXISTS (SELECT 1 FROM windows w WHERE w.session_id = s.id)
     OR EXISTS (SELECT 1 FROM frames f WHERE f.session_id = s.id)
     OR EXISTS (SELECT 1 FROM unavailable_spans u WHERE u.session_id = s.id))
    """

    static let sessionSummarySQL = """
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

    static func fetchFrames(
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

    static func screenshotRecord(_ row: Row) -> ScreenshotRecord? {
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

    static func sessionSummary(_ row: Row) -> CaptureSessionSummary? {
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

    static func spoolRow(frameID: UUID, requiredState: String, db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: spoolSelectSQL + " WHERE f.id = ? AND a.state = ?",
            arguments: [frameID.databaseID, requiredState]
        )
    }

    static func spoolRegistration(_ row: Row) -> SpoolFrameRegistration? {
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

    static func storedSpoolFrame(_ row: Row) -> StoredSpoolFrame? {
        guard let registration = spoolRegistration(row) else { return nil }
        return StoredSpoolFrame(registration: registration, byteCount: row["asset_byte_count"])
    }

    static func spoolRecoveryItem(_ row: Row) -> SpoolFrameRecoveryItem? {
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

    static func segmentManifest(jobID: String, db: Database) throws -> SegmentJobManifest? {
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

    struct FrameDescriptor {
        var whereSQL: String
        var arguments: StatementArguments
    }

    static func frameDescriptor(_ query: FrameQuery, after: FrameCursor?) -> FrameDescriptor {
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

    static func frameCount(query: FrameQuery, db: Database) throws -> Int {
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

    static func sessionExists(_ id: UUID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ? AND state <> 'tombstoned')", arguments: [id.databaseID]) ?? false
    }

    static func sessionIsEmpty(_ id: UUID, db: Database) throws -> Bool {
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

    static func requireSessionAndWindow(sessionID: UUID, windowID: UUID, db: Database) throws {
        guard try sessionExists(sessionID, db: db) else { throw CaptureEngineError.sessionNotFound(sessionID) }
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM windows WHERE id = ? AND session_id = ?)",
            arguments: [windowID.databaseID, sessionID.databaseID]
        ) ?? false else { throw PersistenceStoreError.windowNotFound(windowID) }
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    struct TitleObservation {
        var id: UUID
        var title: String?
        var observedAt: Date
    }

    struct TitleSegmentFallback {
        var id: UUID
        var title: String?
        var bornAt: Date
        var diedAt: Date
    }

    static func titleObservation(_ row: Row) -> TitleObservation? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        return TitleObservation(id: id, title: row["title"], observedAt: Date(databaseTime: row["observed_at"]))
    }

    static func titleSegments(
        observations: [TitleObservation],
        fallback: TitleSegmentFallback,
        screenshotTimes: [Date]
    ) -> [WindowTitleSegment] {
        let fallbackID = fallback.id
        let fallbackTitle = fallback.title
        let bornAt = fallback.bornAt
        let diedAt = fallback.diedAt
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

    static func timelineEntries(
        screenshots: [ScreenshotRecord],
        unavailableRecords: [CaptureUnavailableRecord]
    ) -> [CaptureTimelineEntry] {
        (screenshots.map(CaptureTimelineEntry.screenshot) + unavailableRecords.map(CaptureTimelineEntry.unavailable))
            .sorted { $0.occurredAt < $1.occurredAt }
    }
}
