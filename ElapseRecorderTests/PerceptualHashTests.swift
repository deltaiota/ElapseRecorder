import CoreGraphics
@testable import ElapseRecorder
import XCTest

final class PerceptualHashTests: XCTestCase {
    func testHashKeepsAllEightColumnComparisonsInDisplayRowOrder() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 90, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for column in 0 ... 8 {
            let level = CGFloat(column) / 8
            context.setFillColor(CGColor(gray: level, alpha: 1))
            context.fill(CGRect(x: column * 10, y: 0, width: 10, height: 40))
            context.setFillColor(CGColor(gray: 1 - level, alpha: 1))
            context.fill(CGRect(x: column * 10, y: 40, width: 10, height: 40))
        }
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(PerceptualHashClient.liveValue.hash(CapturedImage(cgImage: image)), 0x0000_0000_FFFF_FFFF)
    }
}
