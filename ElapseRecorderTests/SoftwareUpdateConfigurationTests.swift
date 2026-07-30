@testable import ElapseRecorder
import Foundation
import XCTest

final class SoftwareUpdateConfigurationTests: XCTestCase {
    func testSparkleConfigurationUsesSignedAutomaticChecks() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)

        XCTAssertEqual(
            info["SUFeedURL"] as? String,
            "https://github.com/deltaiota/ElapseRecorder/releases/latest/download/appcast.xml"
        )
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)

        let publicKey = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
    }
}
