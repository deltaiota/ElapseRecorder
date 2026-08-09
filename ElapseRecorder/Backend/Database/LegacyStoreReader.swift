import Foundation
import GRDB

nonisolated extension LegacyStoreImporter {
    static func loadSnapshot(_ database: Database) throws -> Snapshot {
        try validateLegacySchema(database)
        return try Snapshot(
            sessions: loadSessions(database),
            windows: loadWindows(database),
            frames: loadFrames(database),
            titles: loadTitles(database),
            unavailable: loadUnavailable(database)
        )
    }

    private static func validateLegacySchema(_ database: Database) throws {
        let requiredTables = [
            "ZCAPTURESESSIONMODEL",
            "ZMONITOREDWINDOWMODEL",
            "ZSCREENSHOTRECORDMODEL",
            "ZWINDOWTITLEOBSERVATIONMODEL",
            "ZCAPTUREUNAVAILABLERECORDMODEL",
        ]
        for table in requiredTables where try !database.tableExists(table) {
            throw LegacyImportError.missingTable(table)
        }
    }

    private static func loadSessions(_ database: Database) throws -> [LegacySession] {
        try Row.fetchAll(database, sql: """
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
    }

    private static func loadWindows(_ database: Database) throws -> [LegacyWindow] {
        try Row.fetchAll(database, sql: """
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
    }

    private static func loadFrames(_ database: Database) throws -> [LegacyFrame] {
        try Row.fetchAll(database, sql: """
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
    }

    private static func loadTitles(_ database: Database) throws -> [LegacyTitle] {
        try Row.fetchAll(database, sql: """
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
    }

    private static func loadUnavailable(_ database: Database) throws -> [LegacyUnavailable] {
        try Row.fetchAll(database, sql: """
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
}
