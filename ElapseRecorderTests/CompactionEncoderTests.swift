import AVFoundation
@testable import ElapseRecorder
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class CompactionEncoderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "compaction-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeFrame(index: Int, width: Int, height: Int) throws -> CompactableFrame {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // A distinct solid color per frame so we can verify frame indexing after round-trip.
        context.setFillColor(red: Double(index) / 10.0, green: 0.4, blue: 0.75, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let url = directory.appending(path: "frame-\(index).heic")
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try data.write(to: url)

        return CompactableFrame(
            id: UUID(),
            sourceURL: url,
            pixelWidth: width,
            pixelHeight: height,
            capturedAt: Date(timeIntervalSince1970: Double(index))
        )
    }

    private func centerRed(_ image: CGImage) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return Int(pixel[0])
    }

    func testCompactsAndExtractsFramesRoundTrip() async throws {
        let width = 320, height = 240
        let frames = try (0 ..< 10).map { try writeFrame(index: $0, width: width, height: height) }
        let output = directory.appending(path: "window-1.mov")
        let plan = WindowCompactionPlan(
            windowID: UUID(),
            displayNumber: 1,
            outputURL: output,
            canvasWidth: width,
            canvasHeight: height,
            frames: frames
        )

        let size = try await FrameVideoCompactorClient.liveValue.compact(plan, 0.65)
        XCTAssertGreaterThan(size, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        // The compacted video should be smaller than the sum of its source frames.
        let sourceTotal = try frames.reduce(0) {
            try $0 + (FileManager.default.attributesOfItem(atPath: $1.sourceURL.path)[.size] as! Int)
        }
        XCTAssertLessThan(size, sourceTotal)

        // Extract by frame index and confirm correct dimensions + that distinct frames differ.
        let first = try await VideoFrameExtractorClient.liveValue.image(output, 0)
        let last = try await VideoFrameExtractorClient.liveValue.image(output, 9)
        XCTAssertEqual(first.width, width)
        XCTAssertEqual(first.height, height)
        XCTAssertGreaterThan(centerRed(last) - centerRed(first), 80)
    }

    func testDerivesCanvasFromFirstFrameWhenDimensionsUnknown() async throws {
        let width = 200, height = 120
        let frames = try (0 ..< 8).map { try writeFrame(index: $0, width: width, height: height) }
        let output = directory.appending(path: "window-2.mov")
        let plan = WindowCompactionPlan(
            windowID: UUID(),
            displayNumber: 2,
            outputURL: output,
            canvasWidth: 0,
            canvasHeight: 0,
            frames: frames
        )

        let size = try await FrameVideoCompactorClient.liveValue.compact(plan, 0.6)
        XCTAssertGreaterThan(size, 0)
        let image = try await VideoFrameExtractorClient.liveValue.image(output, 3)
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
    }
}
