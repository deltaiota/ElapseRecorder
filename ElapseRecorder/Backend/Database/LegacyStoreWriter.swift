import Foundation
import GRDB

nonisolated extension LegacyStoreImporter {
    static func importSnapshot(_ snapshot: Snapshot, into database: Database) throws {
        let sessionsByPrimaryKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.primaryKey, $0) })
        let windowsByPrimaryKey = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.primaryKey, $0) })
        try insertSessions(snapshot.sessions, into: database)
        try insertWindows(snapshot.windows, sessions: sessionsByPrimaryKey, into: database)
        let assets = try collectAssets(
            frames: snapshot.frames,
            sessions: sessionsByPrimaryKey,
            windows: windowsByPrimaryKey
        )
        try insertAssets(assets.values, into: database)
        try insertFrames(
            snapshot.frames,
            sessions: sessionsByPrimaryKey,
            windows: windowsByPrimaryKey,
            assets: assets,
            into: database
        )
        try insertTitles(snapshot.titles, windows: windowsByPrimaryKey, into: database)
        try insertUnavailable(snapshot.unavailable, sessions: sessionsByPrimaryKey, into: database)
    }

    private static func insertSessions(_ sessions: [LegacySession], into database: Database) throws {
        for session in sessions {
            try database.execute(
                sql: """
                INSERT INTO sessions
                    (id, bundle_identifier, display_name, process_identifier, started_at, ended_at, state)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id.uuidString, session.bundleIdentifier, session.displayName,
                    session.processIdentifier, session.startedAt.timeIntervalSince1970,
                    session.endedAt?.timeIntervalSince1970,
                    session.endedAt == nil ? CaptureSessionDatabaseState.open.rawValue : CaptureSessionDatabaseState.closed.rawValue,
                ]
            )
        }
    }

    private static func insertWindows(
        _ windows: [LegacyWindow],
        sessions: [Int64: LegacySession],
        into database: Database
    ) throws {
        for window in windows {
            guard let session = sessions[window.sessionPrimaryKey] else {
                throw LegacyImportError.missingSession(window.sessionPrimaryKey)
            }
            try database.execute(
                sql: """
                INSERT INTO windows
                    (id, session_id, system_window_id, display_number, label, first_seen_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    window.id.uuidString, session.id.uuidString, window.systemWindowID,
                    max(1, window.displayNumber), window.label, window.firstSeenAt.timeIntervalSince1970,
                    window.lastSeenAt.timeIntervalSince1970,
                ]
            )
        }
    }

    private static func collectAssets(
        frames: [LegacyFrame],
        sessions: [Int64: LegacySession],
        windows: [Int64: LegacyWindow]
    ) throws -> [String: AssetImport] {
        var assets: [String: AssetImport] = [:]
        for frame in frames {
            guard let session = sessions[frame.sessionPrimaryKey] else {
                throw LegacyImportError.missingSession(frame.sessionPrimaryKey)
            }
            guard let window = windows[frame.windowPrimaryKey] else {
                throw LegacyImportError.missingWindow(frame.windowPrimaryKey)
            }
            let path = frame.videoPath ?? frame.filePath
            if var asset = assets[path] {
                guard asset.sessionID == session.id, asset.windowID == window.id else {
                    throw LegacyImportError.sharedAssetAcrossWindows(path)
                }
                asset.frameCount += 1
                asset.pixelWidth = max(asset.pixelWidth, frame.pixelWidth)
                asset.pixelHeight = max(asset.pixelHeight, frame.pixelHeight)
                asset.createdAt = min(asset.createdAt, frame.capturedAt)
                assets[path] = asset
            } else {
                assets[path] = makeAsset(frame: frame, sessionID: session.id, windowID: window.id, path: path)
            }
        }
        return assets
    }

    private static func makeAsset(
        frame: LegacyFrame,
        sessionID: UUID,
        windowID: UUID,
        path: String
    ) -> AssetImport {
        let kind: MediaAssetKind = frame.videoPath == nil ? .spoolImage : .videoSegment
        return AssetImport(
            id: kind == .spoolImage ? frame.id : UUID(),
            sessionID: sessionID,
            windowID: windowID,
            kind: kind,
            path: path,
            byteCount: kind == .videoSegment ? fileSize(at: path) : frame.fileSizeBytes,
            pixelWidth: frame.pixelWidth,
            pixelHeight: frame.pixelHeight,
            frameCount: 1,
            createdAt: frame.capturedAt
        )
    }

    private static func insertAssets(_ assets: Dictionary<String, AssetImport>.Values, into database: Database) throws {
        for asset in assets {
            try database.execute(
                sql: """
                INSERT INTO media_assets
                    (id, session_id, window_id, kind, state, path, byte_count, pixel_width, pixel_height,
                     frame_count, created_at, ready_at)
                VALUES (?, ?, ?, ?, 'ready', ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    asset.id.uuidString, asset.sessionID.uuidString, asset.windowID.uuidString,
                    asset.kind.rawValue, asset.path, asset.byteCount, asset.pixelWidth, asset.pixelHeight,
                    asset.frameCount, asset.createdAt.timeIntervalSince1970, asset.createdAt.timeIntervalSince1970,
                ]
            )
        }
    }

    private static func insertFrames(
        _ frames: [LegacyFrame],
        sessions: [Int64: LegacySession],
        windows: [Int64: LegacyWindow],
        assets: [String: AssetImport],
        into database: Database
    ) throws {
        for frame in frames {
            guard let session = sessions[frame.sessionPrimaryKey],
                  let window = windows[frame.windowPrimaryKey],
                  let asset = assets[frame.videoPath ?? frame.filePath]
            else { throw LegacyImportError.invalidFrame(frame.id) }
            try insertFrame(frame, session: session, window: window, asset: asset, into: database)
        }
    }

    private static func insertFrame(
        _ frame: LegacyFrame,
        session: LegacySession,
        window: LegacyWindow,
        asset: AssetImport,
        into database: Database
    ) throws {
        let videoIndex = frame.videoPath == nil ? nil : frame.videoFrameIndex
        let offset = max(0, frame.capturedAt.timeIntervalSince(session.startedAt))
        let scheduledOffset = Int64(min(Double(Int64.max), offset * 1_000_000_000))
        try database.execute(
            sql: """
            INSERT INTO frames
                (id, session_id, window_id, asset_id, asset_frame_index, asset_pts_value,
                 asset_pts_timescale, captured_at, spool_path, image_format, pixel_width,
                 pixel_height, perceptual_hash, process_identifier, generation, cycle_sequence,
                 scheduled_offset_nanoseconds, request_started_at, completed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
            """,
            arguments: [
                frame.id.uuidString, session.id.uuidString, window.id.uuidString, asset.id.uuidString,
                videoIndex, videoIndex.map { Int64($0) }, videoIndex.map { _ in legacyVideoTimescale },
                frame.capturedAt.timeIntervalSince1970, frame.filePath,
                imageFormat(for: frame.filePath).rawValue, frame.pixelWidth, frame.pixelHeight,
                frame.perceptualHash, session.processIdentifier, max(0, frame.primaryKey), scheduledOffset,
                frame.capturedAt.timeIntervalSince1970, frame.capturedAt.timeIntervalSince1970,
            ]
        )
    }

    private static func insertTitles(
        _ titles: [LegacyTitle],
        windows: [Int64: LegacyWindow],
        into database: Database
    ) throws {
        for title in titles {
            guard let window = windows[title.windowPrimaryKey] else {
                throw LegacyImportError.missingWindow(title.windowPrimaryKey)
            }
            try database.execute(
                sql: "INSERT INTO title_observations (id, window_id, title, observed_at) VALUES (?, ?, ?, ?)",
                arguments: [title.id.uuidString, window.id.uuidString, title.title, title.observedAt.timeIntervalSince1970]
            )
        }
    }

    private static func insertUnavailable(
        _ unavailableRecords: [LegacyUnavailable],
        sessions: [Int64: LegacySession],
        into database: Database
    ) throws {
        for unavailable in unavailableRecords {
            guard let session = sessions[unavailable.sessionPrimaryKey] else {
                throw LegacyImportError.missingSession(unavailable.sessionPrimaryKey)
            }
            try database.execute(
                sql: "INSERT INTO unavailable_spans (id, session_id, started_at, ended_at, reason) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    unavailable.id.uuidString, session.id.uuidString, unavailable.startedAt.timeIntervalSince1970,
                    unavailable.endedAt.timeIntervalSince1970, unavailable.reason,
                ]
            )
        }
    }

    private static func imageFormat(for path: String) -> CaptureImageFormat {
        URL(filePath: path).pathExtension.lowercased() == CaptureImageFormat.png.fileExtension ? .png : .heic
    }

    private static func fileSize(at path: String) -> Int {
        (try? URL(filePath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
