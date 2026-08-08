import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class ViewerFeatureTests: XCTestCase {
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

    @MainActor
    func testIntegritySweepPrunesMissingRecordsAndOrphanFiles() async throws {
        let orphanURL = URL(filePath: "/captures/orphan.heic")
        let missingID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"))

        let deletedRecordIDs = LockIsolated<[UUID]>([])
        let removedFileURLs = LockIsolated<[URL]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.maintenanceServiceClient.integritySweep = { _ in
                deletedRecordIDs.setValue([missingID])
                removedFileURLs.setValue([orphanURL])
                return StorageIntegrityResult(
                    removedRecordCount: 1,
                    removedFileCount: 1,
                    reclaimedBytes: 20
                )
            }
            $0.persistenceClient.apps = { [] }
        }
        store.exhaustivity = .off

        await store.send(.runIntegritySweepButtonTapped) {
            $0.isRunningStorageMaintenance = true
        }
        await store.skipReceivedActions()

        XCTAssertEqual(deletedRecordIDs.value, [missingID])
        XCTAssertEqual(removedFileURLs.value, [orphanURL])
        XCTAssertEqual(
            store.state.storageIntegrityResult,
            StorageIntegrityResult(removedRecordCount: 1, removedFileCount: 1, reclaimedBytes: 20)
        )
        XCTAssertFalse(store.state.isRunningStorageMaintenance)
    }

    @MainActor
    func testBulkDeleteRemovesMatchingSessionsFilesAndRecords() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000B1"))
        let deletedSessionIDs = LockIsolated<[UUID]>([])
        let removedFileURLs = LockIsolated<[URL]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.maintenanceServiceClient.deleteBefore = { cutoff, bundleIdentifier, _ in
                XCTAssertEqual(cutoff, Date(timeIntervalSince1970: 500))
                XCTAssertNil(bundleIdentifier)
                deletedSessionIDs.setValue([sessionID])
                removedFileURLs.setValue([
                    URL(filePath: "/captures/1.heic"),
                    URL(filePath: "/captures/2.heic"),
                ])
                return 1
            }
            $0.persistenceClient.apps = { [] }
        }
        store.exhaustivity = .off

        await store.send(.bulkDeleteRequested(before: Date(timeIntervalSince1970: 500), bundleIdentifier: nil)) {
            $0.isRunningStorageMaintenance = true
        }
        await store.skipReceivedActions()

        XCTAssertEqual(deletedSessionIDs.value, [sessionID])
        XCTAssertEqual(
            removedFileURLs.value,
            [URL(filePath: "/captures/1.heic"), URL(filePath: "/captures/2.heic")]
        )
        XCTAssertFalse(store.state.isRunningStorageMaintenance)
    }

    @MainActor
    func testRetentionPrunesOldestByCountLimitOnly() async {
        // Three ended sessions, 5 screenshots each = 15 total; cap at 8 → delete the two oldest.
        let sessions = (0 ..< 3).map { index in
            CaptureSessionSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000C\(index)0\(index)")!,
                bundleIdentifier: "com.example.App",
                displayName: "App",
                startedAt: Date(timeIntervalSince1970: TimeInterval(100 + index * 100)),
                endedAt: Date(timeIntervalSince1970: TimeInterval(150 + index * 100)),
                windowCount: 1,
                screenshotCount: 5,
                sizeBytes: 50
            )
        }
        let deleted = LockIsolated<[UUID]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.date = .constant(Date(timeIntervalSince1970: 10000))
            $0.capturePreferencesClient.retentionPolicy = {
                RetentionPolicy(maxAge: nil, maxTotalBytes: nil, maxScreenshotCount: 8)
            }
            $0.maintenanceServiceClient.enforceRetention = { policy, now, _ in
                let ids = policy.sessionIDsToPrune(
                    snapshot: RetentionSnapshot(
                        endedSessionsOldestFirst: sessions,
                        activeSizeBytes: 0,
                        activeFrameCount: 0
                    ),
                    now: now
                )
                deleted.setValue(ids)
                return ids.count
            }
            $0.persistenceClient.apps = { [] }
        }
        store.exhaustivity = .off

        await store.send(.enforceRetentionRequested) {
            $0.isEnforcingRetention = true
        }
        await store.skipReceivedActions()

        // Deleting the two oldest leaves 5 <= 8.
        XCTAssertEqual(deleted.value, [sessions[0].id, sessions[1].id])
        XCTAssertFalse(store.state.isEnforcingRetention)
    }

    @MainActor
    func testRetentionNoOpWhenPolicyDisabled() async {
        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.capturePreferencesClient.retentionPolicy = { .none }
        }

        // With no active limits the request is ignored: no state change, no effects.
        await store.send(.enforceRetentionRequested)
    }

    @MainActor
    func testCaptureScreenshotUpdatesVisibleStateIncrementally() async {
        let bundleIdentifier = "com.example.ArtApp"
        let sessionID = UUID()
        let windowID = UUID()
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let previousCapture = Date(timeIntervalSince1970: 110)
        let capturedAt = Date(timeIntervalSince1970: 112)
        let record = ScreenshotRecord(
            id: UUID(),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: capturedAt,
            fileURL: URL(filePath: "/tmp/frame.heic"),
            fileSizeBytes: 5
        )

        var state = ViewerFeature.State()
        state.apps = [
            AppCaptureSummary(
                bundleIdentifier: bundleIdentifier,
                displayName: "Art App",
                sessionCount: 1,
                screenshotCount: 10,
                lastCapturedAt: previousCapture,
                sizeBytes: 100,
                totalActiveDuration: 10
            ),
        ]
        state.sessions = [
            CaptureSessionSummary(
                id: sessionID,
                bundleIdentifier: bundleIdentifier,
                displayName: "Art App",
                startedAt: startedAt,
                endedAt: nil,
                windowCount: 1,
                screenshotCount: 10,
                sizeBytes: 100
            ),
        ]
        state.windows = [
            WindowCaptureSummary(
                id: windowID,
                displayNumber: 1,
                label: "Canvas",
                firstSeenAt: startedAt,
                lastSeenAt: previousCapture,
                screenshotCount: 10
            ),
        ]
        state.selectedBundleIdentifier = bundleIdentifier
        state.selectedSessionID = sessionID
        state.selectedWindowID = windowID
        state.sessionTimeline = SessionTimeline(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: nil,
            lanes: [
                WindowLane(
                    windowID: windowID,
                    displayNumber: 1,
                    systemWindowID: 1,
                    bornAt: startedAt,
                    diedAt: previousCapture,
                    segments: [
                        WindowTitleSegment(
                            id: segmentID,
                            title: "Canvas",
                            startedAt: startedAt,
                            endedAt: Date(timeIntervalSince1970: 200),
                            screenshotCount: 10
                        ),
                    ],
                    screenshotCount: 10
                ),
            ],
            unavailableSpans: []
        )

        let store = TestStore(initialState: state) {
            ViewerFeature()
        }

        await store.send(.captureScreenshotRecorded(record, bundleIdentifier: bundleIdentifier)) {
            $0.apps[0].screenshotCount = 11
            $0.apps[0].lastCapturedAt = capturedAt
            $0.apps[0].sizeBytes = 105
            $0.apps[0].totalActiveDuration = 12
            $0.sessions[0].screenshotCount = 11
            $0.sessions[0].sizeBytes = 105
            $0.windows[0].screenshotCount = 11
            $0.windowTimelineEntries = [.screenshot(record)]
            $0.sessionTimeline?.lanes[0].diedAt = capturedAt
            $0.sessionTimeline?.lanes[0].segments[0].screenshotCount = 11
            $0.sessionTimeline?.lanes[0].screenshotCount = 11
        }
    }

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

    func testRetentionPolicySelectsByAgeAndSize() {
        let now = Date(timeIntervalSince1970: 10000)
        func session(_ n: Int, started: TimeInterval, bytes: Int) -> CaptureSessionSummary {
            CaptureSessionSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D\(n)")!,
                bundleIdentifier: "b", displayName: "b",
                startedAt: Date(timeIntervalSince1970: started), endedAt: Date(timeIntervalSince1970: started + 1),
                windowCount: 1, screenshotCount: 1, sizeBytes: bytes
            )
        }
        let sessions = [
            session(0, started: 1000, bytes: 100), // oldest
            session(1, started: 5000, bytes: 100),
            session(2, started: 9000, bytes: 100), // newest
        ]

        // Age: keep only sessions newer than now-2000s (i.e. started > 8000) → prune 0 and 1.
        let ageOnly = RetentionPolicy(maxAge: 2000, maxTotalBytes: nil, maxScreenshotCount: nil)
        XCTAssertEqual(
            ageOnly.sessionIDsToPrune(endedSessionsOldestFirst: sessions, now: now),
            [sessions[0].id, sessions[1].id]
        )

        // Size: 300 total, cap 150 → delete oldest until <=150 (drop 0 then 1 → 100 left).
        let sizeOnly = RetentionPolicy(maxAge: nil, maxTotalBytes: 150, maxScreenshotCount: nil)
        XCTAssertEqual(
            sizeOnly.sessionIDsToPrune(endedSessionsOldestFirst: sessions, now: now),
            [sessions[0].id, sessions[1].id]
        )

        // No limits → nothing pruned.
        XCTAssertEqual(RetentionPolicy.none.sessionIDsToPrune(endedSessionsOldestFirst: sessions, now: now), [])
    }

    @MainActor
    func testSelectingSessionLoadsWindowsAndTimelineGraph() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000601"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000602"))
        let window = WindowCaptureSummary(
            id: windowID,
            displayNumber: 1,
            label: "Canvas",
            firstSeenAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 200),
            screenshotCount: 1
        )
        let timeline = SessionTimeline(
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            lanes: [
                WindowLane(
                    windowID: windowID,
                    displayNumber: 1,
                    systemWindowID: 5,
                    bornAt: Date(timeIntervalSince1970: 100),
                    diedAt: Date(timeIntervalSince1970: 200),
                    segments: [
                        WindowTitleSegment(
                            id: windowID,
                            title: "Canvas",
                            startedAt: Date(timeIntervalSince1970: 100),
                            endedAt: Date(timeIntervalSince1970: 200),
                            screenshotCount: 1
                        ),
                    ],
                    screenshotCount: 1
                ),
            ],
            unavailableSpans: []
        )
        var state = ViewerFeature.State()
        state.selectedBundleIdentifier = "com.example.ArtApp"

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.windows = { _ in [window] }
            $0.persistenceClient.sessionTimeline = { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
                return timeline
            }
        }

        await store.send(.sessionSelected(sessionID)) {
            $0.selectedSessionID = sessionID
            $0.isLoading = true
        }
        await store.receive(.windowsLoaded([window])) {
            $0.windows = [window]
            $0.isLoading = false
        }
        await store.receive(.sessionTimelineLoaded(timeline)) {
            $0.sessionTimeline = timeline
        }
        XCTAssertTrue(store.state.isShowingTimelineGraph)
        XCTAssertEqual(store.state.windowPickerSelection, .all)
    }

    @MainActor
    func testLiveFrameUpdatesPagedCountAndLaterPageDoesNotDuplicate() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000680"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000681"))
        let existing = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000682")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 1),
            fileURL: URL(filePath: "/tmp/existing.heic"),
            fileSizeBytes: 10
        )
        let live = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000683")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 2),
            fileURL: URL(filePath: "/tmp/live.heic"),
            fileSizeBytes: 10
        )
        let query = FrameQuery(scope: .window(sessionID: sessionID, windowID: windowID))
        var state = ViewerFeature.State()
        state.selectedBundleIdentifier = "com.example.App"
        state.selectedSessionID = sessionID
        state.sessions = [CaptureSessionSummary(
            id: sessionID,
            bundleIdentifier: "com.example.App",
            displayName: "App",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: nil,
            windowCount: 1,
            screenshotCount: 1
        )]
        state.windows = [WindowCaptureSummary(
            id: windowID,
            displayNumber: 1,
            label: nil,
            firstSeenAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 1),
            screenshotCount: 1
        )]
        state.selectedWindowID = windowID
        state.frameQuery = query
        state.windowTimelineEntries = [.screenshot(existing)]
        state.frameTotalCount = 1

        let store = TestStore(initialState: state) { ViewerFeature() }
        store.exhaustivity = .off
        await store.send(.captureScreenshotRecorded(live, bundleIdentifier: "com.example.App"))
        XCTAssertEqual(store.state.frameTotalCount, 2)
        XCTAssertEqual(store.state.windowTimelineEntries.map(\.id), [existing.id, live.id])

        await store.send(.framePageLoaded(
            query: query,
            page: FramePage(frames: [live], nextCursor: nil, totalCount: 2),
            appending: true
        ))
        XCTAssertEqual(store.state.windowTimelineEntries.map(\.id), [existing.id, live.id])
    }

    @MainActor
    func testSelectingWindowThenReturningToTimeline() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000604"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000605"))
        let windowScreenshot = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000607")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 175),
            fileURL: URL(filePath: "/tmp/window.heic"),
            fileSizeBytes: 2048
        )
        var state = ViewerFeature.State()
        state.selectedSessionID = sessionID

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.framePage = { query, _, _ in
                XCTAssertEqual(query, FrameQuery(scope: .window(sessionID: sessionID, windowID: windowID)))
                return FramePage(frames: [windowScreenshot], nextCursor: nil, totalCount: 1)
            }
        }
        store.exhaustivity = .off

        await store.send(.windowPickerSelectionChanged(.window(id: windowID)))
        await store.skipReceivedActions()
        XCTAssertEqual(store.state.windowTimelineEntries, [.screenshot(windowScreenshot)])
        XCTAssertEqual(store.state.frameTotalCount, 1)
        XCTAssertFalse(store.state.isShowingTimelineGraph)

        // Clearing the window selection returns to the timeline graph without loading a grid.
        await store.send(.windowPickerSelectionChanged(.all)) {
            $0.selectedWindowID = nil
            $0.windowTimelineEntries = []
        }
        XCTAssertTrue(store.state.isShowingTimelineGraph)
    }

    @MainActor
    func testSelectingWindowSegmentFiltersGridToSegmentRange() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000620"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000621"))
        let inRange = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000622")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 160),
            fileURL: URL(filePath: "/tmp/in.heic"),
            fileSizeBytes: 10
        )
        let outOfRange = try ScreenshotRecord(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000623")),
            windowID: windowID,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 260),
            fileURL: URL(filePath: "/tmp/out.heic"),
            fileSizeBytes: 10
        )
        let segment = try WindowTitleSegment(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000624")),
            title: "Untitled",
            startedAt: Date(timeIntervalSince1970: 150),
            endedAt: Date(timeIntervalSince1970: 200),
            screenshotCount: 1
        )
        var state = ViewerFeature.State()
        state.selectedSessionID = sessionID

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.framePage = { query, _, _ in
                XCTAssertEqual(
                    query,
                    FrameQuery(
                        scope: .window(sessionID: sessionID, windowID: windowID),
                        capturedAt: segment.startedAt ... segment.endedAt
                    )
                )
                return FramePage(frames: [inRange], nextCursor: nil, totalCount: 1)
            }
        }
        store.exhaustivity = .off

        await store.send(.windowSegmentSelected(windowID: windowID, segment: segment))
        await store.skipReceivedActions()
        XCTAssertEqual(store.state.windowTimelineEntries, [.screenshot(inRange)])
        XCTAssertFalse(store.state.windowTimelineEntries.contains(.screenshot(outOfRange)))
    }

    @MainActor
    func testWindowPickerSelectingCurrentItemDoesNotReloadScreenshots() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000608"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000609"))
        var state = ViewerFeature.State()
        state.selectedSessionID = sessionID
        state.selectedWindowID = windowID

        let windowTimelineLoadCount = LockIsolated(0)
        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.timelineForWindow = { _, _ in
                windowTimelineLoadCount.withValue { $0 += 1 }
                return []
            }
        }

        // Re-selecting the current window is a no-op.
        await store.send(.windowPickerSelectionChanged(.window(id: windowID)))
        XCTAssertEqual(windowTimelineLoadCount.value, 0)

        // Returning to the timeline graph loads no grid.
        await store.send(.windowPickerSelectionChanged(.all)) {
            $0.selectedWindowID = nil
        }
        XCTAssertEqual(windowTimelineLoadCount.value, 0)
        XCTAssertTrue(store.state.isShowingTimelineGraph)

        // Already on the timeline graph; selecting "all" again is a no-op.
        await store.send(.windowPickerSelectionChanged(.all))
        XCTAssertEqual(windowTimelineLoadCount.value, 0)
    }

    @MainActor
    func testDeleteSelectedEndedSessionDeletesFilesAndMetadataThenRefreshes() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000501"))
        let session = CaptureSessionSummary(
            id: sessionID,
            bundleIdentifier: "com.example.DeleteApp",
            displayName: "Delete App",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            windowCount: 1,
            screenshotCount: 2
        )
        let deletedFileSessions = LockIsolated([(String, UUID)]())
        let deletedMetadataSessions = LockIsolated([UUID]())

        var state = ViewerFeature.State()
        state.apps = [
            AppCaptureSummary(
                bundleIdentifier: session.bundleIdentifier,
                displayName: session.displayName,
                sessionCount: 1,
                screenshotCount: 2,
                lastCapturedAt: Date(timeIntervalSince1970: 150)
            ),
        ]
        state.sessions = [session]
        state.selectedBundleIdentifier = session.bundleIdentifier
        state.selectedSessionID = session.id

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.maintenanceServiceClient.deleteSessions = { ids, _ in
                deletedFileSessions.setValue([(session.bundleIdentifier, session.id)])
                deletedMetadataSessions.setValue(ids)
                return ids.count
            }
            $0.persistenceClient.apps = { [] }
            $0.persistenceClient.sessions = { _ in [] }
            $0.persistenceClient.windows = { _ in [] }
        }
        store.exhaustivity = .off

        await store.send(.deleteSelectedSessionButtonTapped) {
            $0.isLoading = true
        }
        await store.receive(.sessionDeleted(session.id)) {
            $0.selectedSessionID = nil
            $0.windows = []
            $0.windowTimelineEntries = []
            $0.isLoading = false
        }

        XCTAssertEqual(deletedFileSessions.value.map(\.0), [session.bundleIdentifier])
        XCTAssertEqual(deletedFileSessions.value.map(\.1), [session.id])
        XCTAssertEqual(deletedMetadataSessions.value, [session.id])
    }

    @MainActor
    func testDeleteSpecificUnselectedEndedSessionKeepsCurrentSelection() async throws {
        let selectedSessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000503"))
        let deletedSessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000504"))
        let selectedSession = CaptureSessionSummary(
            id: selectedSessionID,
            bundleIdentifier: "com.example.DeleteApp",
            displayName: "Delete App",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            windowCount: 1,
            screenshotCount: 2
        )
        let deletedSession = CaptureSessionSummary(
            id: deletedSessionID,
            bundleIdentifier: "com.example.DeleteApp",
            displayName: "Delete App",
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 400),
            windowCount: 1,
            screenshotCount: 2
        )
        let deletedFileSessions = LockIsolated([(String, UUID)]())
        let deletedMetadataSessions = LockIsolated([UUID]())

        var state = ViewerFeature.State()
        state.sessions = [selectedSession, deletedSession]
        state.selectedBundleIdentifier = selectedSession.bundleIdentifier
        state.selectedSessionID = selectedSession.id

        let store = TestStore(initialState: state) {
            ViewerFeature()
        } withDependencies: {
            $0.maintenanceServiceClient.deleteSessions = { ids, _ in
                deletedFileSessions.setValue([(deletedSession.bundleIdentifier, deletedSession.id)])
                deletedMetadataSessions.setValue(ids)
                return ids.count
            }
            $0.persistenceClient.apps = { [] }
            $0.persistenceClient.sessions = { _ in [] }
            $0.persistenceClient.windows = { _ in [] }
        }
        store.exhaustivity = .off

        await store.send(.deleteSessionButtonTapped(deletedSession)) {
            $0.isLoading = true
        }
        await store.receive(.sessionDeleted(deletedSession.id)) {
            $0.isLoading = false
        }

        XCTAssertEqual(deletedFileSessions.value.map(\.0), [deletedSession.bundleIdentifier])
        XCTAssertEqual(deletedFileSessions.value.map(\.1), [deletedSession.id])
        XCTAssertEqual(deletedMetadataSessions.value, [deletedSession.id])
    }

    @MainActor
    func testDeleteSelectedOpenSessionIsBlocked() async throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000502"))
        let session = CaptureSessionSummary(
            id: sessionID,
            bundleIdentifier: "com.example.ActiveApp",
            displayName: "Active App",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            windowCount: 1,
            screenshotCount: 2
        )
        var state = ViewerFeature.State()
        state.sessions = [session]
        state.selectedBundleIdentifier = session.bundleIdentifier
        state.selectedSessionID = session.id

        let store = TestStore(initialState: state) {
            ViewerFeature()
        }

        await store.send(.deleteSelectedSessionButtonTapped) {
            $0.errorMessage = "Stop capture before deleting an active session."
        }
    }
}
