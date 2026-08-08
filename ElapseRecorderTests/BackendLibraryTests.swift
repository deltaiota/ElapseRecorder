import ComposableArchitecture
import CoreGraphics
import CoreMedia
@testable import ElapseRecorder
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class BackendLibraryTests: XCTestCase {
    func testFramePageLoaderWalksExclusiveKeysetPagesWithoutMaterializingScope() async throws {
        let sessionID = UUID()
        let windowID = UUID()
        let frames = (0 ..< 5).map { index in
            ScreenshotRecord(
                id: UUID(),
                windowID: windowID,
                sessionID: sessionID,
                capturedAt: Date(timeIntervalSince1970: Double(index)),
                fileURL: URL(filePath: "/tmp/\(index).heic"),
                fileSizeBytes: 1
            )
        }
        let calls = LockIsolated(0)
        var persistence = PersistenceClient.unimplemented
        persistence.framePage = { _, after, limit in
            calls.withValue { $0 += 1 }
            let start = after.flatMap { cursor in frames.firstIndex { $0.id == cursor.id } }.map { $0 + 1 } ?? 0
            let pageFrames = Array(frames.dropFirst(start).prefix(limit))
            let next = start + pageFrames.count < frames.count ? pageFrames.last.map { FrameCursor(frame: $0) } : nil
            return FramePage(frames: pageFrames, nextCursor: next, totalCount: frames.count)
        }
        persistence.frameCount = { _ in frames.count }
        persistence.frameQuerySnapshot = { query in
            FrameQuerySnapshot(selection: .query(query), count: frames.count)
        }
        persistence.framesByID = { ids in ids.compactMap { id in frames.first { $0.id == id } } }

        let loader = FramePageLoader(persistence: persistence)
        let query = FrameQuery(scope: .window(sessionID: sessionID, windowID: windowID))
        var loaded: [UUID] = []
        for try await frame in loader.records(for: .query(query), pageSize: 2) {
            loaded.append(frame.id)
        }

        XCTAssertEqual(loaded, frames.map(\.id))
        XCTAssertEqual(Set(loaded).count, frames.count)
        XCTAssertEqual(calls.value, 3)
    }

    func testStreamingCadenceExcludesCrossWindowAndSessionGaps() async throws {
        let sessionID = UUID()
        let firstWindow = UUID()
        let secondWindow = UUID()
        let frames = [
            record(sessionID: sessionID, windowID: firstWindow, time: 0),
            record(sessionID: sessionID, windowID: secondWindow, time: 100),
            record(sessionID: sessionID, windowID: firstWindow, time: 10),
            record(sessionID: sessionID, windowID: secondWindow, time: 120),
        ]
        var persistence = PersistenceClient.unimplemented
        persistence.framePage = { _, after, _ in
            after == nil
                ? FramePage(frames: frames, nextCursor: nil, totalCount: frames.count)
                : .empty
        }
        persistence.frameCount = { _ in frames.count }
        persistence.frameQuerySnapshot = { query in
            FrameQuerySnapshot(selection: .query(query), count: frames.count)
        }
        persistence.framesByID = { _ in [] }
        let loader = FramePageLoader(persistence: persistence)

        let average = try await loader.averageInterval(
            for: .query(FrameQuery(scope: .app(bundleIdentifier: "example")))
        )
        XCTAssertEqual(average, 15) // (10 + 20) / 2, never the 90-second cross-window gap.
    }

    func testFrameReaderBoundsConcurrentDecodeAndReusesVideoDecoder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "frame-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appending(path: "frame.png")
        try Self.writeImage(to: imageURL)

        let reader = FrameReader(maximumConcurrentDecodes: 2, videoCacheLimit: 2)
        _ = try await reader.images(
            for: Array(repeating: FrameSource.file(imageURL), count: 8),
            maximumPixelSize: 8
        )
        var diagnostics = await reader.diagnostics()
        XCTAssertGreaterThan(diagnostics.maximumObservedConcurrentDecodes, 0)
        XCTAssertLessThanOrEqual(diagnostics.maximumObservedConcurrentDecodes, 2)

        let videoURL = directory.appending(path: "missing.mov")
        let exactTime = FramePresentationTime(value: 7, timescale: 1000)
        _ = try? await reader.image(for: .videoFrame(video: videoURL, presentationTime: exactTime))
        _ = try? await reader.image(for: .videoFrame(video: videoURL, presentationTime: exactTime))
        diagnostics = await reader.diagnostics()
        XCTAssertEqual(diagnostics.createdVideoDecoders, 1)
        let mediaTime = FrameReader.mediaTime(for: exactTime)
        XCTAssertEqual(mediaTime.value, 7)
        XCTAssertEqual(mediaTime.timescale, 1000) // Regression: never infer a 30 Hz seek time.
    }

    private func record(sessionID: UUID, windowID: UUID, time: TimeInterval) -> ScreenshotRecord {
        ScreenshotRecord(
            id: UUID(),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: time),
            fileURL: URL(filePath: "/tmp/\(UUID().uuidString).heic"),
            fileSizeBytes: 1
        )
    }

    private static func writeImage(to url: URL) throws {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
