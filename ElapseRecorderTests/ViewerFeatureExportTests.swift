import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class ViewerFeatureExportTests: XCTestCase {
    @MainActor
    func testExportTimelapseChoosesDestinationEncodesAndReveals() async {
        let frames = [
            ExportFrame(url: URL(filePath: "/tmp/a.heic"), pixelWidth: 800, pixelHeight: 600),
            ExportFrame(url: URL(filePath: "/tmp/b.heic"), pixelWidth: 800, pixelHeight: 600),
        ]
        let destination = URL(filePath: "/tmp/out.mp4")
        let revealed = LockIsolated<URL?>(nil)
        let startedAt = Date(timeIntervalSince1970: 1000)
        let options = ExportOptions(codec: .hevc, container: .mov, framesPerSecond: 24, interpolationFrames: 3)
        // 2 source frames + 3 crossfades between them = 5 output frames.
        let totalFrames = 5

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.date = .constant(startedAt)
            $0.exportPanelClient.present = { _, _ in
                ExportSelection(destinationURL: destination, options: options)
            }
            $0.timelapseExportClient.export = { request in
                AsyncThrowingStream { continuation in
                    Task {
                        do {
                            var actualFrames: [ExportFrame] = []
                            for try await frame in request.source.stream() {
                                actualFrames.append(frame)
                            }
                            XCTAssertEqual(actualFrames, frames)
                            XCTAssertEqual(request.destinationURL, destination)
                            XCTAssertEqual(request.codec, .hevc)
                            XCTAssertEqual(request.container, .mov)
                            XCTAssertEqual(request.framesPerSecond, 24)
                            XCTAssertEqual(request.interpolationFrames, 3)
                            XCTAssertEqual(request.outputFrameCount, totalFrames)
                            continuation.yield(TimelapseExportProgress(emittedFrames: 2, totalFrames: totalFrames))
                            continuation.yield(TimelapseExportProgress(emittedFrames: 5, totalFrames: totalFrames))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
            $0.fileRevealClient.reveal = { url in revealed.setValue(url) }
        }

        await store.send(.exportTimelapseRequested(frames: frames)) {
            $0.isExporting = true
        }
        await store.receive(\.exportStarted) {
            $0.exportStatus = TimelapseExportStatus(
                options: options,
                totalFrames: totalFrames,
                emittedFrames: 0,
                startedAt: startedAt
            )
        }
        await store.receive(\.exportProgressed) {
            $0.exportStatus?.emittedFrames = 2
        }
        await store.receive(\.exportProgressed) {
            $0.exportStatus?.emittedFrames = 5
        }
        await store.receive(\.exportCompleted) {
            $0.isExporting = false
            $0.exportStatus = nil
        }
        XCTAssertEqual(revealed.value, destination)
    }

    private static func makeImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    @MainActor
    func testExportTimelapseCancelledWhenNoDestinationChosen() async {
        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.exportPanelClient.present = { _, _ in nil }
            $0.fileRevealClient.reveal = { _ in }
        }

        await store.send(.exportTimelapseRequested(frames: [ExportFrame(url: URL(filePath: "/tmp/a.heic"))])) {
            $0.isExporting = true
        }
        await store.receive(\.exportCancelled) {
            $0.isExporting = false
        }
    }

    @MainActor
    func testExportCancelButtonCancelsInFlightExport() async {
        let startedAt = Date(timeIntervalSince1970: 2000)
        let options = ExportOptions(codec: .h264, container: .mp4, framesPerSecond: 24, interpolationFrames: 0)

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.date = .constant(startedAt)
            $0.exportPanelClient.present = { _, _ in
                ExportSelection(destinationURL: URL(filePath: "/tmp/out.mp4"), options: options)
            }
            $0.timelapseExportClient.export = { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(TimelapseExportProgress(emittedFrames: 1, totalFrames: 2))
                    // Stay open so the export is still in flight when we cancel it.
                }
            }
            $0.fileRevealClient.reveal = { _ in }
        }

        await store.send(.exportTimelapseRequested(frames: [
            ExportFrame(url: URL(filePath: "/tmp/a.heic")),
            ExportFrame(url: URL(filePath: "/tmp/b.heic")),
        ])) {
            $0.isExporting = true
        }
        await store.receive(\.exportStarted) {
            $0.exportStatus = TimelapseExportStatus(
                options: options,
                totalFrames: 2,
                emittedFrames: 0,
                startedAt: startedAt
            )
        }
        await store.receive(\.exportProgressed) {
            $0.exportStatus?.emittedFrames = 1
        }
        await store.send(.exportCancelButtonTapped) {
            $0.isExporting = false
            $0.exportStatus = nil
        }
    }

    // MARK: - Storage management (Phase 2)

    func testExportFrameFilterDropsSimilarKeepsUnknownHashes() {
        // 1 vs 255 differ by 7 bits (> threshold 4) → kept; equal hashes dropped.
        XCTAssertEqual(ExportFrameFilter.keptIndices(hashes: [1, 1, 255, 255, 1]), [0, 2, 4])
        // Unknown hashes (0) are always kept so old libraries aren't thinned.
        XCTAssertEqual(ExportFrameFilter.keptIndices(hashes: [0, 0, 0]), [0, 1, 2])
        XCTAssertEqual(ExportFrameFilter.keptIndices(hashes: []), [])
    }

    @MainActor
    func testExportAppliesTrimAndSkipSimilar() async {
        let frames = (0 ..< 5).map { index in
            ExportFrame(
                url: URL(filePath: "/tmp/\(index).heic"),
                pixelWidth: 100,
                pixelHeight: 100,
                perceptualHash: [1, 1, 255, 255, 1][index]
            )
        }
        // Trim to indices 1...4 → [1,255,255,1]; then skip-similar keeps 1,255,1 → frames 1,2,4.
        let options = ExportOptions(
            codec: .h264, container: .mp4, framesPerSecond: 24, interpolationFrames: 0,
            trimRange: 1 ... 4, skipSimilarFrames: true
        )
        let encodedFrames = LockIsolated<[ExportFrame]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.exportPanelClient.present = { _, _ in
                ExportSelection(destinationURL: URL(filePath: "/tmp/out.mp4"), options: options)
            }
            $0.timelapseExportClient.export = { request in
                AsyncThrowingStream { continuation in
                    Task {
                        do {
                            var streamedFrames: [ExportFrame] = []
                            for try await frame in request.source.stream() {
                                streamedFrames.append(frame)
                            }
                            let collectedFrames = streamedFrames
                            encodedFrames.setValue(collectedFrames)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
            $0.fileRevealClient.reveal = { _ in }
        }
        store.exhaustivity = .off

        await store.send(.exportTimelapseRequested(frames: frames))
        await store.skipReceivedActions()

        XCTAssertEqual(encodedFrames.value.map(\.url.lastPathComponent), ["1.heic", "2.heic", "4.heic"])
    }

    @MainActor
    func testExportResolvesSegmentHashesBeforeSkippingSimilarFrames() async {
        let videoURL = URL(filePath: "/tmp/compacted.mov")
        let frames = (0 ..< 5).map { (index: Int) in
            ExportFrame(
                url: URL(filePath: "/tmp/deleted-\(index).heic"),
                pixelWidth: 100,
                pixelHeight: 100,
                perceptualHash: 0,
                videoURL: videoURL,
                videoFrameIndex: index,
                videoPTSValue: Int64(index),
                videoPTSTimescale: 30
            )
        }
        let options = ExportOptions(
            codec: .h264, container: .mp4, framesPerSecond: 24, interpolationFrames: 0,
            skipSimilarFrames: true
        )
        let hashes = LockIsolated<[UInt64]>([1, 1, 255, 255, 1])
        let encodedFrames = LockIsolated<[ExportFrame]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.exportPanelClient.present = { _, _ in
                ExportSelection(destinationURL: URL(filePath: "/tmp/out.mp4"), options: options)
            }
            $0.thumbnailClient.thumbnail = { _, _ in Self.makeImage() }
            $0.perceptualHashClient.hash = { _ in
                hashes.withValue { $0.removeFirst() }
            }
            $0.timelapseExportClient.export = { request in
                AsyncThrowingStream { continuation in
                    Task {
                        do {
                            var streamedFrames: [ExportFrame] = []
                            for try await frame in request.source.stream() {
                                streamedFrames.append(frame)
                            }
                            let collectedFrames = streamedFrames
                            encodedFrames.setValue(collectedFrames)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
            $0.fileRevealClient.reveal = { _ in }
        }
        store.exhaustivity = .off

        await store.send(.exportTimelapseRequested(frames: frames))
        await store.skipReceivedActions()

        XCTAssertEqual(encodedFrames.value.map(\.videoFrameIndex), [0, 2, 4])
    }
}
