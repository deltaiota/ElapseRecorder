import Foundation
import GRDB

/// One-time, lossless metadata cutover from the SwiftData/Core Data store shipped before backend V2.
/// The source store is retained as a backup. The durable marker is committed in the same transaction
/// as every imported row, so interruption can only produce a complete import or no import.
nonisolated enum LegacyStoreImporter {
    static let importIdentifier = "swiftdata-v1"
    static let legacyVideoTimescale: Int32 = 30

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

    struct Snapshot {
        var sessions: [LegacySession]
        var windows: [LegacyWindow]
        var frames: [LegacyFrame]
        var titles: [LegacyTitle]
        var unavailable: [LegacyUnavailable]
    }

    struct LegacySession {
        var primaryKey: Int64
        var id: UUID
        var bundleIdentifier: String
        var displayName: String
        var processIdentifier: Int64
        var startedAt: Date
        var endedAt: Date?
    }

    struct LegacyWindow {
        var primaryKey: Int64
        var id: UUID
        var sessionPrimaryKey: Int64
        var systemWindowID: Int64
        var displayNumber: Int
        var firstSeenAt: Date
        var lastSeenAt: Date
        var label: String?
    }

    struct LegacyFrame {
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

    struct LegacyTitle {
        var id: UUID
        var windowPrimaryKey: Int64
        var observedAt: Date
        var title: String?
    }

    struct LegacyUnavailable {
        var id: UUID
        var sessionPrimaryKey: Int64
        var startedAt: Date
        var endedAt: Date
        var reason: String
    }

    struct AssetImport {
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
}

nonisolated enum LegacyImportError: Error {
    case missingTable(String)
    case invalidUUID(String)
    case missingSession(Int64)
    case missingWindow(Int64)
    case sharedAssetAcrossWindows(String)
    case invalidFrame(UUID)
}
