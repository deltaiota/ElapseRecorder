import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class BackendV2IntegrationTests: XCTestCase {
    @MainActor
    func testCapturedFramesAutomaticallyBecomeVerifiedHEVCSegment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "backend-v2-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try ElapseDatabase(url: root.appending(path: "library.sqlite"))
        let persistence = PersistenceClient.live(database: database)
        var files = FileStorageClient.liveValue
        files.captureRoot = { root }
        files.spoolFrameURL = { _, windowID, frameID, format in
            let directory = root.appending(path: "spool/\(windowID.uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appending(path: "\(frameID.uuidString).\(format.fileExtension)")
        }
        files.segmentAssetURLs = { _, assetID in
            let directory = root.appending(path: "segments", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return (
                directory.appending(path: "\(assetID.uuidString).partial.mov"),
                directory.appending(path: "\(assetID.uuidString).mov")
            )
        }
        files.availableCapacity = { Int64.max }
        files.probeWritable = {}

        let configuration = StorageCoordinatorConfiguration(
            queueCapacity: 4,
            maximumSpoolBytes: 64 * 1024 * 1024,
            minimumFreeDiskBytes: 0,
            segmentTarget: SegmentTarget(maximumFrames: 3, maximumDuration: 60, maximumBytes: 64 * 1024 * 1024),
            mediaTimescale: 30,
            leaseDuration: 60,
            recoveryBatchSize: 100
        )
        let storage = StorageCoordinatorClient.live(
            configuration: configuration,
            persistence: persistence,
            fileStorage: files,
            imageEncoder: .liveValue,
            segmentWriter: .liveValue,
            segmentQuality: { 0.65 },
            now: Date.init,
            makeID: UUID.init
        )

        let sessionID = UUID()
        let windowID = UUID()
        let session = CaptureSession(
            id: sessionID,
            bundleIdentifier: "com.example.BackendSmoke",
            displayName: "Backend Smoke",
            processIdentifier: 42,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let window = MonitoredWindow(
            id: windowID,
            sessionID: sessionID,
            systemWindowID: 7,
            displayNumber: 1,
            label: "Canvas",
            firstSeenAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 102)
        )
        try await persistence.openSession(session)
        try await persistence.upsertWindow(window)

        let handle = RecordingSessionHandle(
            sessionID: sessionID,
            bundleIdentifier: session.bundleIdentifier,
            processIdentifier: session.processIdentifier,
            generation: 1
        )
        var events = await storage.events().makeAsyncIterator()
        for index in 0 ..< 3 {
            let capturedAt = Date(timeIntervalSince1970: 100 + Double(index))
            let envelope = CapturedFrameEnvelope(
                id: UUID(),
                handle: handle,
                cycleSequence: Int64(index + 1),
                scheduledOffsetNanoseconds: Int64(index) * 1_000_000_000,
                requestStartedAt: capturedAt,
                completedAt: capturedAt,
                window: CapturedWindowMetadata(
                    windowID: windowID,
                    systemWindowID: window.systemWindowID,
                    displayNumber: window.displayNumber,
                    title: window.label
                ),
                image: ImmutableCapturedImage(Self.makeImage(index: index)),
                encodingOptions: CaptureEncodingOptions(format: .heic, heicQuality: 0.82),
                perceptualHash: UInt64(index + 1)
            )
            let result = await storage.enqueue(envelope)
            XCTAssertEqual(result, .accepted(frameID: envelope.id))
        }

        let segmentURL = try await Self.nextSegmentURL(events: &events)
        let frames = try await persistence.screenshotsForWindow(windowID)
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.videoURL == segmentURL })
        XCTAssertEqual(frames.compactMap(\.videoFrameIndex), [0, 1, 2])
        XCTAssertEqual(frames.compactMap(\.videoPTSValue), [0, 1, 2])
        XCTAssertTrue(frames.allSatisfy { $0.videoPTSTimescale == 30 })
        XCTAssertTrue(frames.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })

        let first = try await FrameReader.shared.image(for: frames[0].frameSource)
        let last = try await FrameReader.shared.image(for: frames[2].frameSource)
        XCTAssertEqual(first.width, 320)
        XCTAssertEqual(first.height, 200)
        XCTAssertEqual(last.width, 320)
        XCTAssertEqual(last.height, 200)

        try await storage.flushSession(handle)
        try await persistence.closeSession(sessionID, Date(timeIntervalSince1970: 103))
        XCTAssertTrue(FileManager.default.fileExists(atPath: segmentURL.path))
    }

    private static func nextSegmentURL(
        events: inout AsyncStream<StorageCoordinatorEvent>.AsyncIterator
    ) async throws -> URL {
        while let event = await events.next() {
            switch event {
            case let .segmentCommitted(_, _, _, url):
                return url
            case let .storageDegraded(reason):
                throw IntegrationTestError.storageDegraded(String(describing: reason))
            default:
                continue
            }
        }
        throw IntegrationTestError.missingSegmentCommit
    }

    private static func makeImage(index: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: 320,
            height: 200,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(
            red: CGFloat(index) / 3,
            green: 0.35,
            blue: 0.8,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        return context.makeImage()!
    }
}

private enum IntegrationTestError: Error {
    case missingSegmentCommit
    case storageDegraded(String)
}
