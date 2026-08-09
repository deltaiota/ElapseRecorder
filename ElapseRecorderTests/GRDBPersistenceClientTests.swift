@testable import ElapseRecorder
import Foundation
import XCTest

class GRDBPersistenceTestCase: XCTestCase {
    func temporaryClient() throws -> PersistenceClient {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ElapseRecorder-GRDBTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let database = try ElapseDatabase(url: directory.appending(path: "test.sqlite"))
        return .live(database: database)
    }

    func uuid(_ string: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: string))
    }
}
