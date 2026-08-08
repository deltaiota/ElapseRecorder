@testable import ElapseRecorder
import Foundation
import GRDB
import XCTest

final class LegacyStoreImporterTests: XCTestCase {
    func testImportsSwiftDataStoreOnceWithExactLegacyVideoTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "legacy-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appending(path: "ElapseRecorder.store")
        let databaseURL = directory.appending(path: "ElapseRecorder-v2.sqlite")
        let videoURL = directory.appending(path: "window-1.mov")
        try Data("legacy-video".utf8).write(to: videoURL)

        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000701"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000702"))
        let frameID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000703"))
        let titleID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000704"))
        let unavailableID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000705"))
        let startedAt = Date(timeIntervalSince1970: 1000)
        let capturedAt = Date(timeIntervalSince1970: 1005)
        let endedAt = Date(timeIntervalSince1970: 1010)

        try makeLegacyStore(
            at: legacyURL,
            sessionID: sessionID,
            windowID: windowID,
            frameID: frameID,
            titleID: titleID,
            unavailableID: unavailableID,
            videoURL: videoURL,
            startedAt: startedAt,
            capturedAt: capturedAt,
            endedAt: endedAt
        )

        let database = try ElapseDatabase(url: databaseURL)
        try LegacyStoreImporter.importIfNeeded(from: legacyURL, into: database)
        try LegacyStoreImporter.importIfNeeded(from: legacyURL, into: database)
        let client = PersistenceClient.live(database: database)

        let sessions = try await client.sessions("com.example.Legacy")
        XCTAssertEqual(sessions.map(\.id), [sessionID])
        XCTAssertEqual(sessions.first?.screenshotCount, 1)
        let frames = try await client.screenshotsForSession(sessionID)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frame.id, frameID)
        XCTAssertEqual(frame.videoURL, videoURL)
        XCTAssertEqual(frame.videoPTSValue, 7)
        XCTAssertEqual(frame.videoPTSTimescale, 30)
        XCTAssertEqual(frame.capturedAt, capturedAt)
        let timeline = try await client.sessionTimeline(sessionID)
        XCTAssertEqual(timeline.lanes.first?.segments.first?.title, "Legacy Document")
        XCTAssertEqual(timeline.unavailableSpans.count, 1)
    }

    private func makeLegacyStore(
        at url: URL,
        sessionID: UUID,
        windowID: UUID,
        frameID: UUID,
        titleID: UUID,
        unavailableID: UUID,
        videoURL: URL,
        startedAt: Date,
        capturedAt: Date,
        endedAt: Date
    ) throws {
        let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
        try queue.write { database in
            try database.execute(sql: """
            CREATE TABLE ZCAPTURESESSIONMODEL (
                Z_PK INTEGER PRIMARY KEY, ZID BLOB, ZBUNDLEIDENTIFIER TEXT, ZDISPLAYNAME TEXT,
                ZPROCESSIDENTIFIER INTEGER, ZSTARTEDAT REAL, ZENDEDAT REAL
            );
            CREATE TABLE ZMONITOREDWINDOWMODEL (
                Z_PK INTEGER PRIMARY KEY, ZID BLOB, ZSESSION INTEGER, ZSYSTEMWINDOWID INTEGER,
                ZDISPLAYNUMBER INTEGER, ZFIRSTSEENAT REAL, ZLASTSEENAT REAL, ZLABEL TEXT
            );
            CREATE TABLE ZSCREENSHOTRECORDMODEL (
                Z_PK INTEGER PRIMARY KEY, ZID BLOB, ZSESSION INTEGER, ZWINDOW INTEGER,
                ZCAPTUREDAT REAL, ZFILEPATH TEXT, ZFILESIZEBYTES INTEGER, ZPIXELWIDTH INTEGER,
                ZPIXELHEIGHT INTEGER, ZPERCEPTUALHASH INTEGER, ZVIDEOPATH TEXT, ZVIDEOFRAMEINDEX INTEGER
            );
            CREATE TABLE ZWINDOWTITLEOBSERVATIONMODEL (
                Z_PK INTEGER PRIMARY KEY, ZID BLOB, ZWINDOW INTEGER, ZOBSERVEDAT REAL, ZTITLE TEXT
            );
            CREATE TABLE ZCAPTUREUNAVAILABLERECORDMODEL (
                Z_PK INTEGER PRIMARY KEY, ZID BLOB, ZSESSION INTEGER, ZSTARTEDAT REAL,
                ZENDEDAT REAL, ZREASON TEXT
            );
            """)
            try database.execute(
                sql: "INSERT INTO ZCAPTURESESSIONMODEL VALUES (1, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    uuidData(sessionID), "com.example.Legacy", "Legacy", 42,
                    startedAt.timeIntervalSinceReferenceDate, endedAt.timeIntervalSinceReferenceDate,
                ]
            )
            try database.execute(
                sql: "INSERT INTO ZMONITOREDWINDOWMODEL VALUES (1, ?, 1, 7, 1, ?, ?, ?)",
                arguments: [
                    uuidData(windowID), startedAt.timeIntervalSinceReferenceDate,
                    endedAt.timeIntervalSinceReferenceDate, "Legacy Document",
                ]
            )
            try database.execute(
                sql: "INSERT INTO ZSCREENSHOTRECORDMODEL VALUES (1, ?, 1, 1, ?, ?, 99, 1920, 1080, 123, ?, 7)",
                arguments: [
                    uuidData(frameID), capturedAt.timeIntervalSinceReferenceDate,
                    directoryURL(url).appending(path: "deleted.heic").path,
                    videoURL.path(percentEncoded: false),
                ]
            )
            try database.execute(
                sql: "INSERT INTO ZWINDOWTITLEOBSERVATIONMODEL VALUES (1, ?, 1, ?, ?)",
                arguments: [uuidData(titleID), capturedAt.timeIntervalSinceReferenceDate, "Legacy Document"]
            )
            try database.execute(
                sql: "INSERT INTO ZCAPTUREUNAVAILABLERECORDMODEL VALUES (1, ?, 1, ?, ?, ?)",
                arguments: [
                    uuidData(unavailableID), capturedAt.timeIntervalSinceReferenceDate,
                    endedAt.timeIntervalSinceReferenceDate, "windowMinimized",
                ]
            )
        }
    }

    private func uuidData(_ id: UUID) -> Data {
        let hexadecimal = id.uuidString.replacingOccurrences(of: "-", with: "")
        return Data(stride(from: 0, to: hexadecimal.count, by: 2).compactMap { offset in
            let start = hexadecimal.index(hexadecimal.startIndex, offsetBy: offset)
            let end = hexadecimal.index(start, offsetBy: 2)
            return UInt8(hexadecimal[start ..< end], radix: 16)
        })
    }

    private func directoryURL(_ fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
    }
}
