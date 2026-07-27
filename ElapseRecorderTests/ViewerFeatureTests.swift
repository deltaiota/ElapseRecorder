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
                    XCTAssertEqual(request.frames, frames)
                    XCTAssertEqual(request.destinationURL, destination)
                    XCTAssertEqual(request.codec, .hevc)
                    XCTAssertEqual(request.container, .mov)
                    XCTAssertEqual(request.framesPerSecond, 24)
                    XCTAssertEqual(request.interpolationFrames, 3)
                    XCTAssertEqual(request.outputFrameCount, totalFrames)
                    continuation.yield(TimelapseExportProgress(emittedFrames: 2, totalFrames: totalFrames))
                    continuation.yield(TimelapseExportProgress(emittedFrames: 5, totalFrames: totalFrames))
                    continuation.finish()
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

    @MainActor
    func testCompactStorageEncodesVerifiesRepointsAndDeletesOriginals() async {
        let sessionID = UUID()
        let windowID = UUID()
        let frames = (0 ..< 4).map { index in
            CompactableFrame(
                id: UUID(),
                sourceURL: URL(filePath: "/tmp/w/\(index).heic"),
                pixelWidth: 100,
                pixelHeight: 100,
                capturedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let plan = SessionCompactionPlan(
            sessionID: sessionID,
            windows: [
                WindowCompactionPlan(
                    windowID: windowID,
                    displayNumber: 1,
                    outputURL: URL(filePath: "/tmp/w/window-1.mov"),
                    canvasWidth: 100,
                    canvasHeight: 100,
                    frames: frames
                ),
            ]
        )
        let summary = CaptureSessionSummary(
            id: sessionID,
            bundleIdentifier: "com.example.App",
            displayName: "App",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 100),
            windowCount: 1,
            screenshotCount: 4
        )

        let appliedVideoPath = LockIsolated<String?>(nil)
        let appliedRecordIDs = LockIsolated<[UUID]>([])
        let removedURLs = LockIsolated<[URL]>([])
        let verifiedIndex = LockIsolated<Int?>(nil)

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.endedSessionsOldestFirst = { [summary] }
            $0.persistenceClient.compactionPlanForSession = { $0 == sessionID ? plan : nil }
            $0.persistenceClient.apps = { [] }
            $0.frameVideoCompactorClient.compact = { _, _, _ in 1000 }
            $0.videoFrameExtractorClient.image = { _, index in
                verifiedIndex.setValue(index)
                return Self.makeImage()
            }
            $0.persistenceClient.applyCompaction = { window, videoPath, ids, _ in
                XCTAssertEqual(window, windowID)
                appliedVideoPath.setValue(videoPath)
                appliedRecordIDs.setValue(ids)
            }
            $0.fileStorageClient.removeFiles = { urls in
                removedURLs.setValue(urls)
                return 4000
            }
        }
        store.exhaustivity = .off

        await store.send(.compactStorageButtonTapped) {
            $0.isCompacting = true
        }
        await store.receive(\.compactionFinished) {
            $0.isCompacting = false
            $0.compactionResult = StorageCompactionResult(
                compactedWindowCount: 1,
                framesCompacted: 4,
                bytesBefore: 4000,
                bytesAfter: 1000
            )
        }

        XCTAssertEqual(appliedVideoPath.value, "/tmp/w/window-1.mov")
        XCTAssertEqual(appliedRecordIDs.value, frames.map(\.id))
        XCTAssertEqual(removedURLs.value, frames.map(\.sourceURL))
        XCTAssertEqual(verifiedIndex.value, 3) // last frame verified
    }

    @MainActor
    func testCompactStorageWithNothingToCompactReportsEmpty() async {
        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.endedSessionsOldestFirst = { [] }
            $0.fileStorageClient.removeFiles = { _ in 0 }
        }

        await store.send(.compactStorageButtonTapped) {
            $0.isCompacting = true
        }
        await store.receive(\.compactionFinished) {
            $0.isCompacting = false
            $0.compactionResult = .empty
        }
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
    func testAutoCompactOnSessionCloseSkippedWhenToggleDisabled() async {
        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.capturePreferencesClient.autoCompactOnSessionClose = { false }
        }

        // Toggle off: the automatic request is a no-op (no encoding, no state change).
        await store.send(.autoCompactOnSessionCloseRequested)
    }

    @MainActor
    func testAutoCompactOnSessionCloseRunsWhenToggleEnabled() async {
        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.capturePreferencesClient.autoCompactOnSessionClose = { true }
            $0.persistenceClient.endedSessionsOldestFirst = { [] }
            $0.fileStorageClient.removeFiles = { _ in 0 }
        }

        await store.send(.autoCompactOnSessionCloseRequested) {
            $0.isCompacting = true
        }
        await store.receive(\.compactionFinished) {
            $0.isCompacting = false
            $0.compactionResult = .empty
        }
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
        let keepPath = "/captures/keep.heic"
        let missingPath = "/captures/missing.heic"
        let orphanURL = URL(filePath: "/captures/orphan.heic")
        let keptID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"))
        let missingID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"))

        let deletedRecordIDs = LockIsolated<[UUID]>([])
        let removedFileURLs = LockIsolated<[URL]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.screenshotFileIndex = {
                [
                    ScreenshotFileReference(id: keptID, path: keepPath, sizeBytes: 10),
                    ScreenshotFileReference(id: missingID, path: missingPath, sizeBytes: 20),
                ]
            }
            $0.persistenceClient.deleteScreenshots = { ids in deletedRecordIDs.setValue(ids) }
            $0.persistenceClient.apps = { [] }
            $0.fileStorageClient.captureFileURLs = { [URL(filePath: keepPath), orphanURL] }
            $0.fileStorageClient.filterExistingPaths = { paths in Set(paths.filter { $0 == keepPath }) }
            $0.fileStorageClient.removeFiles = { urls in
                removedFileURLs.setValue(urls)
                return 20
            }
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
        let session = CaptureSessionSummary(
            id: sessionID,
            bundleIdentifier: "com.example.App",
            displayName: "App",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            windowCount: 1,
            screenshotCount: 3,
            sizeBytes: 30
        )
        let deletedSessionIDs = LockIsolated<[UUID]>([])
        let removedFileURLs = LockIsolated<[URL]>([])

        let store = TestStore(initialState: ViewerFeature.State()) {
            ViewerFeature()
        } withDependencies: {
            $0.persistenceClient.sessionsStartedBefore = { _, _ in [session] }
            $0.persistenceClient.screenshotPathsForSession = { _ in ["/captures/1.heic", "/captures/2.heic"] }
            $0.persistenceClient.deleteSession = { id in deletedSessionIDs.withValue { $0.append(id) } }
            $0.persistenceClient.apps = { [] }
            $0.fileStorageClient.deleteSessionCaptures = { _, _ in }
            $0.fileStorageClient.removeFiles = { urls in
                removedFileURLs.withValue { $0.append(contentsOf: urls) }
                return 30
            }
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
            $0.persistenceClient.endedSessionsOldestFirst = { sessions }
            $0.persistenceClient.screenshotPathsForSession = { _ in [] }
            $0.persistenceClient.deleteSession = { id in deleted.withValue { $0.append(id) } }
            $0.persistenceClient.apps = { [] }
            $0.fileStorageClient.deleteSessionCaptures = { _, _ in }
            $0.fileStorageClient.removeFiles = { _ in 0 }
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
                encodedFrames.setValue(request.frames)
                return AsyncThrowingStream { $0.finish() }
            }
            $0.fileRevealClient.reveal = { _ in }
        }
        store.exhaustivity = .off

        await store.send(.exportTimelapseRequested(frames: frames))
        await store.skipReceivedActions()

        XCTAssertEqual(encodedFrames.value.map(\.url.lastPathComponent), ["1.heic", "2.heic", "4.heic"])
    }

    @MainActor
    func testExportResolvesLegacyCompactedHashesBeforeSkippingSimilarFrames() async {
        let videoURL = URL(filePath: "/tmp/compacted.mov")
        let frames = (0 ..< 5).map { (index: Int) in
            ExportFrame(
                url: URL(filePath: "/tmp/deleted-\(index).heic"),
                pixelWidth: 100,
                pixelHeight: 100,
                perceptualHash: 0,
                videoURL: videoURL,
                videoFrameIndex: index
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
                encodedFrames.setValue(request.frames)
                return AsyncThrowingStream { $0.finish() }
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
            $0.persistenceClient.timelineForWindow = { _, _ in [.screenshot(windowScreenshot)] }
        }

        // Selecting a window (e.g. tapping its lane) loads that window's screenshots.
        await store.send(.windowPickerSelectionChanged(.window(id: windowID))) {
            $0.selectedWindowID = windowID
            $0.windowTimelineEntries = []
            $0.isShowingFlatGallery = false
            $0.isLoading = true
        }
        await store.receive(.timelineEntriesLoaded([.screenshot(windowScreenshot)])) {
            $0.windowTimelineEntries = [.screenshot(windowScreenshot)]
            $0.isLoading = false
        }
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
            $0.persistenceClient.timelineForWindow = { _, _ in
                [.screenshot(inRange), .screenshot(outOfRange)]
            }
        }

        await store.send(.windowSegmentSelected(windowID: windowID, segment: segment)) {
            $0.selectedWindowID = windowID
            $0.selectedSegment = segment
            $0.windowTimelineEntries = []
            $0.isShowingFlatGallery = false
            $0.isLoading = true
        }
        // Only the screenshot inside the segment's [150, 200] range survives the filter.
        await store.receive(.timelineEntriesLoaded([.screenshot(inRange)])) {
            $0.windowTimelineEntries = [.screenshot(inRange)]
            $0.isLoading = false
        }
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
            $0.fileStorageClient.deleteSessionCaptures = { bundleIdentifier, sessionID in
                deletedFileSessions.withValue { $0.append((bundleIdentifier, sessionID)) }
            }
            $0.persistenceClient.deleteSession = { sessionID in
                deletedMetadataSessions.withValue { $0.append(sessionID) }
            }
            $0.persistenceClient.apps = { [] }
            $0.persistenceClient.sessions = { _ in [] }
            $0.persistenceClient.windows = { _ in [] }
            $0.persistenceClient.timelineForApp = { _ in [] }
            $0.persistenceClient.timelineForSession = { _ in [] }
            $0.persistenceClient.timelineForWindow = { _, _ in [] }
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
            $0.fileStorageClient.deleteSessionCaptures = { bundleIdentifier, sessionID in
                deletedFileSessions.withValue { $0.append((bundleIdentifier, sessionID)) }
            }
            $0.persistenceClient.deleteSession = { sessionID in
                deletedMetadataSessions.withValue { $0.append(sessionID) }
            }
            $0.persistenceClient.apps = { [] }
            $0.persistenceClient.sessions = { _ in [] }
            $0.persistenceClient.windows = { _ in [] }
            $0.persistenceClient.timelineForApp = { _ in [] }
            $0.persistenceClient.timelineForSession = { _ in [] }
            $0.persistenceClient.timelineForWindow = { _, _ in [] }
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
