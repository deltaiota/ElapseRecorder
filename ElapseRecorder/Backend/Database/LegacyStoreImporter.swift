import Foundation
import GRDB

/// One-time, lossless metadata cutover from the SwiftData/Core Data store shipped before backend V2.
/// The source store is retained as a backup. The durable marker is committed in the same transaction
/// as every imported row, so interruption can only produce a complete import or no import.
nonisolated enum LegacyStoreImporter {
    private static let importIdentifier = "swiftdata-v1"
    private static let legacyVideoTimescale: Int32 = 30

    static func importIfNeeded(from legacyURL: URL, into database: ElapseDatabase) throws {
        guard FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)) else { return }
        let alreadyImported = try database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM backend_imports WHERE identifier = ?)",
                arguments: [importIdentifier]
            ) ?? false
        }
        guard !alreadyImported else { return }

        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        let legacy = try DatabaseQueue(
            path: legacyURL.path(percentEncoded: false),
            configuration: configuration
        )
        let snapshot = try legacy.read(loadSnapshot)

        try database.pool.write { db in
            let markerExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM backend_imports WHERE identifier = ?)",
                arguments: [importIdentifier]
            ) ?? false
            guard !markerExists else { return }
            try importSnapshot(snapshot, into: db)
            try db.execute(
                sql: "INSERT INTO backend_imports (identifier, completed_at) VALUES (?, ?)",
                arguments: [importIdentifier, Date().timeIntervalSince1970]
            )
        }
    }

    private struct Snapshot {
        var sessions: [LegacySession]
        var windows: [LegacyWindow]
        var frames: [LegacyFrame]
        var titles: [LegacyTitle]
        var unavailable: [LegacyUnavailable]
    }

    private struct LegacySession {
        var primaryKey: Int64
        var id: UUID
        var bundleIdentifier: String
        var displayName: String
        var processIdentifier: Int64
        var startedAt: Date
        var endedAt: Date?
    }

    private struct LegacyWindow {
        var primaryKey: Int64
        var id: UUID
        var sessionPrimaryKey: Int64
        var systemWindowID: Int64
        var displayNumber: Int
        var firstSeenAt: Date
        var lastSeenAt: Date
        var label: String?
    }

    private struct LegacyFrame {
        var primaryKey: Int64
        var id: UUID
        var sessionPrimaryKey: Int64
        var windowPrimaryKey: Int64
        var capturedAt: Date
        var filePath: String
        var fileSizeBytes: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var perceptualHash: Int64
        var videoPath: String?
        var videoFrameIndex: Int?
    }

    private struct LegacyTitle {
        var id: UUID
        var windowPrimaryKey: Int64
        var observedAt: Date
        var title: String?
    }

    private struct LegacyUnavailable {
        var id: UUID
        var sessionPrimaryKey: Int64
        var startedAt: Date
        var endedAt: Date
        var reason: String
    }

    private struct AssetImport {
        var id: UUID
        var sessionID: UUID
        var windowID: UUID
        var kind: MediaAssetKind
        var path: String
        var byteCount: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var frameCount: Int
        var createdAt: Date
    }

    private static func loadSnapshot(_ db: Database) throws -> Snapshot {
        let requiredTables = [
            "ZCAPTURESESSIONMODEL",
            "ZMONITOREDWINDOWMODEL",
            "ZSCREENSHOTRECORDMODEL",
            "ZWINDOWTITLEOBSERVATIONMODEL",
            "ZCAPTUREUNAVAILABLERECORDMODEL",
        ]
        for table in requiredTables where try !db.tableExists(table) {
            throw LegacyImportError.missingTable(table)
        }

        let sessions = try Row.fetchAll(db, sql: """
        SELECT Z_PK, ZID, ZBUNDLEIDENTIFIER, ZDISPLAYNAME, ZPROCESSIDENTIFIER, ZSTARTEDAT, ZENDEDAT
        FROM ZCAPTURESESSIONMODEL ORDER BY Z_PK
        """).map { row in
            try LegacySession(
                primaryKey: row["Z_PK"],
                id: uuid(row, column: "ZID"),
                bundleIdentifier: row["ZBUNDLEIDENTIFIER"],
                displayName: row["ZDISPLAYNAME"],
                processIdentifier: row["ZPROCESSIDENTIFIER"],
                startedAt: referenceDate(row, column: "ZSTARTEDAT"),
                endedAt: optionalReferenceDate(row, column: "ZENDEDAT")
            )
        }
        let windows = try Row.fetchAll(db, sql: """
        SELECT Z_PK, ZID, ZSESSION, ZSYSTEMWINDOWID, ZDISPLAYNUMBER, ZFIRSTSEENAT, ZLASTSEENAT, ZLABEL
        FROM ZMONITOREDWINDOWMODEL ORDER BY Z_PK
        """).map { row in
            try LegacyWindow(
                primaryKey: row["Z_PK"],
                id: uuid(row, column: "ZID"),
                sessionPrimaryKey: row["ZSESSION"],
                systemWindowID: row["ZSYSTEMWINDOWID"],
                displayNumber: row["ZDISPLAYNUMBER"],
                firstSeenAt: referenceDate(row, column: "ZFIRSTSEENAT"),
                lastSeenAt: referenceDate(row, column: "ZLASTSEENAT"),
                label: row["ZLABEL"]
            )
        }
        let frames = try Row.fetchAll(db, sql: """
        SELECT Z_PK, ZID, ZSESSION, ZWINDOW, ZCAPTUREDAT, ZFILEPATH, ZFILESIZEBYTES,
               ZPIXELWIDTH, ZPIXELHEIGHT, ZPERCEPTUALHASH, ZVIDEOPATH, ZVIDEOFRAMEINDEX
        FROM ZSCREENSHOTRECORDMODEL ORDER BY Z_PK
        """).map { row in
            try LegacyFrame(
                primaryKey: row["Z_PK"],
                id: uuid(row, column: "ZID"),
                sessionPrimaryKey: row["ZSESSION"],
                windowPrimaryKey: row["ZWINDOW"],
                capturedAt: referenceDate(row, column: "ZCAPTUREDAT"),
                filePath: row["ZFILEPATH"],
                fileSizeBytes: max(0, row["ZFILESIZEBYTES"]),
                pixelWidth: max(0, row["ZPIXELWIDTH"]),
                pixelHeight: max(0, row["ZPIXELHEIGHT"]),
                perceptualHash: row["ZPERCEPTUALHASH"],
                videoPath: nonempty(row["ZVIDEOPATH"] as String?),
                videoFrameIndex: row["ZVIDEOFRAMEINDEX"]
            )
        }
        let titles = try Row.fetchAll(db, sql: """
        SELECT ZID, ZWINDOW, ZOBSERVEDAT, ZTITLE
        FROM ZWINDOWTITLEOBSERVATIONMODEL ORDER BY Z_PK
        """).map { row in
            try LegacyTitle(
                id: uuid(row, column: "ZID"),
                windowPrimaryKey: row["ZWINDOW"],
                observedAt: referenceDate(row, column: "ZOBSERVEDAT"),
                title: row["ZTITLE"]
            )
        }
        let unavailable = try Row.fetchAll(db, sql: """
        SELECT ZID, ZSESSION, ZSTARTEDAT, ZENDEDAT, ZREASON
        FROM ZCAPTUREUNAVAILABLERECORDMODEL ORDER BY Z_PK
        """).map { row in
            try LegacyUnavailable(
                id: uuid(row, column: "ZID"),
                sessionPrimaryKey: row["ZSESSION"],
                startedAt: referenceDate(row, column: "ZSTARTEDAT"),
                endedAt: referenceDate(row, column: "ZENDEDAT"),
                reason: row["ZREASON"]
            )
        }
        return Snapshot(
            sessions: sessions,
            windows: windows,
            frames: frames,
            titles: titles,
            unavailable: unavailable
        )
    }

    private static func importSnapshot(_ snapshot: Snapshot, into db: Database) throws {
        let sessionsByPrimaryKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.primaryKey, $0) })
        let windowsByPrimaryKey = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.primaryKey, $0) })

        for session in snapshot.sessions {
            try db.execute(
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
        for window in snapshot.windows {
            guard let session = sessionsByPrimaryKey[window.sessionPrimaryKey] else {
                throw LegacyImportError.missingSession(window.sessionPrimaryKey)
            }
            try db.execute(
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

        var assetsByPath: [String: AssetImport] = [:]
        for frame in snapshot.frames {
            guard let session = sessionsByPrimaryKey[frame.sessionPrimaryKey] else {
                throw LegacyImportError.missingSession(frame.sessionPrimaryKey)
            }
            guard let window = windowsByPrimaryKey[frame.windowPrimaryKey] else {
                throw LegacyImportError.missingWindow(frame.windowPrimaryKey)
            }
            let path = frame.videoPath ?? frame.filePath
            if var asset = assetsByPath[path] {
                guard asset.sessionID == session.id, asset.windowID == window.id else {
                    throw LegacyImportError.sharedAssetAcrossWindows(path)
                }
                asset.frameCount += 1
                asset.pixelWidth = max(asset.pixelWidth, frame.pixelWidth)
                asset.pixelHeight = max(asset.pixelHeight, frame.pixelHeight)
                asset.createdAt = min(asset.createdAt, frame.capturedAt)
                assetsByPath[path] = asset
            } else {
                let kind: MediaAssetKind = frame.videoPath == nil ? .spoolImage : .videoSegment
                assetsByPath[path] = AssetImport(
                    id: kind == .spoolImage ? frame.id : UUID(),
                    sessionID: session.id,
                    windowID: window.id,
                    kind: kind,
                    path: path,
                    byteCount: kind == .videoSegment ? fileSize(at: path) : frame.fileSizeBytes,
                    pixelWidth: frame.pixelWidth,
                    pixelHeight: frame.pixelHeight,
                    frameCount: 1,
                    createdAt: frame.capturedAt
                )
            }
        }
        for asset in assetsByPath.values {
            try db.execute(
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

        for frame in snapshot.frames {
            guard let session = sessionsByPrimaryKey[frame.sessionPrimaryKey],
                  let window = windowsByPrimaryKey[frame.windowPrimaryKey],
                  let asset = assetsByPath[frame.videoPath ?? frame.filePath]
            else { throw LegacyImportError.invalidFrame(frame.id) }
            let videoIndex = frame.videoPath == nil ? nil : frame.videoFrameIndex
            let offset = max(0, frame.capturedAt.timeIntervalSince(session.startedAt))
            let scheduledOffset = Int64(min(Double(Int64.max), offset * 1_000_000_000))
            try db.execute(
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
        for title in snapshot.titles {
            guard let window = windowsByPrimaryKey[title.windowPrimaryKey] else {
                throw LegacyImportError.missingWindow(title.windowPrimaryKey)
            }
            try db.execute(
                sql: "INSERT INTO title_observations (id, window_id, title, observed_at) VALUES (?, ?, ?, ?)",
                arguments: [title.id.uuidString, window.id.uuidString, title.title, title.observedAt.timeIntervalSince1970]
            )
        }
        for unavailable in snapshot.unavailable {
            guard let session = sessionsByPrimaryKey[unavailable.sessionPrimaryKey] else {
                throw LegacyImportError.missingSession(unavailable.sessionPrimaryKey)
            }
            try db.execute(
                sql: "INSERT INTO unavailable_spans (id, session_id, started_at, ended_at, reason) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    unavailable.id.uuidString, session.id.uuidString, unavailable.startedAt.timeIntervalSince1970,
                    unavailable.endedAt.timeIntervalSince1970, unavailable.reason,
                ]
            )
        }
    }

    private static func uuid(_ row: Row, column: String) throws -> UUID {
        let data: Data? = row[column]
        guard let data, data.count == 16 else { throw LegacyImportError.invalidUUID(column) }
        let hex = data.map { String(format: "%02X", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let id = UUID(uuidString: value) else { throw LegacyImportError.invalidUUID(column) }
        return id
    }

    private static func referenceDate(_ row: Row, column: String) -> Date {
        let interval: Double = row[column]
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    private static func optionalReferenceDate(_ row: Row, column: String) -> Date? {
        let interval: Double? = row[column]
        return interval.map(Date.init(timeIntervalSinceReferenceDate:))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func imageFormat(for path: String) -> CaptureImageFormat {
        URL(filePath: path).pathExtension.lowercased() == CaptureImageFormat.png.fileExtension ? .png : .heic
    }

    private static func fileSize(at path: String) -> Int {
        (try? URL(filePath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

private nonisolated enum LegacyImportError: Error {
    case missingTable(String)
    case invalidUUID(String)
    case missingSession(Int64)
    case missingWindow(Int64)
    case sharedAssetAcrossWindows(String)
    case invalidFrame(UUID)
}
