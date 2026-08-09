import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class CaptureEngineFeatureSchedulingTests: CaptureEngineFeatureTestCase {
    func testAbsoluteSchedulerSkipsBusyDeadlinesWithoutCatchUpBurst() async throws {
        let clock = TestClock<Duration>()
        let windowGate = WindowGate()
        let storageEvents = StreamPipe<StorageCoordinatorEvent>()
        let harness = makeHarness(
            clock: clock,
            storageEvents: storageEvents,
            windows: { _ in try await windowGate.next() }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }

        await harness.service.applyWhitelist([harness.config])
        try await eventually { windowGate.requestCount == 1 }

        await clock.advance(by: .seconds(35))
        try await eventually {
            collector.events.contains {
                if case .schedulerDeadlineMissed = $0 { return true }
                return false
            }
        }
        XCTAssertEqual(windowGate.requestCount, 1, "a busy cycle must not be replayed at missed deadlines")

        windowGate.resumeNext(returning: [])
        try await eventually {
            collector.events.contains {
                if case let .sessionUpdated(snapshot) = $0 { return !snapshot.isCaptureInFlight }
                return false
            }
        }

        await clock.advance(by: .seconds(4))
        XCTAssertEqual(windowGate.requestCount, 1)
        await clock.advance(by: .seconds(1))
        try await eventually { windowGate.requestCount == 2 }
    }

    func testIntervalChangeDeterministicallyReanchorsFromChangeInstant() async throws {
        let clock = TestClock<Duration>()
        let requestCount = Locked(0)
        let harness = makeHarness(
            clock: clock,
            windows: { _ in
                requestCount.withValue { $0 += 1 }
                return []
            }
        )
        let stream = await harness.service.start()
        let task = Task { for await _ in stream {} }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually { requestCount.value == 1 }

        await clock.advance(by: .seconds(4))
        var changed = harness.config
        changed.captureInterval = 20
        await harness.service.applyWhitelist([changed])

        await clock.advance(by: .seconds(19))
        XCTAssertEqual(requestCount.value, 1)
        await clock.advance(by: .seconds(1))
        try await eventually { requestCount.value == 2 }
    }

    func testProcessReplacementUsesNewGenerationAndCorrelatedHandle() async throws {
        let clock = TestClock<Duration>()
        let workspaceEvents = StreamPipe<WorkspaceEvent>()
        let harness = makeHarness(
            clock: clock,
            workspaceEvents: workspaceEvents,
            windows: { _ in [] }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually {
            collector.events.filter {
                if case .sessionOpened = $0 { return true }
                return false
            }.count == 1
        }

        workspaceEvents.yield(.terminated(harness.application))
        let replacement = RunningApplication(
            bundleIdentifier: harness.application.bundleIdentifier,
            displayName: harness.application.displayName,
            processIdentifier: 202
        )
        workspaceEvents.yield(.launched(replacement))
        try await eventually {
            collector.events.filter {
                if case .sessionOpened = $0 { return true }
                return false
            }.count >= 2
        }

        let handles = collector.events.compactMap { event -> RecordingSessionHandle? in
            guard case let .sessionOpened(snapshot) = event else { return nil }
            return snapshot.handle
        }
        XCTAssertEqual(handles.map(\.generation), [1, 2])
        XCTAssertEqual(handles.map(\.processIdentifier), [101, 202])
        XCTAssertNotEqual(handles[0].sessionID, handles[1].sessionID)
    }

    func testStopWaitsForCaptureEnqueueAndFlushBeforeClosingMetadata() async throws {
        let clock = TestClock<Duration>()
        let captureGate = CaptureGate()
        let order = Locked<[String]>([])
        let window = CapturableWindow(
            systemWindowID: 42,
            title: "Document",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            layer: 0,
            isOnScreen: true
        )
        let harness = makeHarness(
            clock: clock,
            windows: { _ in [window] },
            capture: { _ in try await captureGate.next() },
            enqueue: { frame in
                order.withValue { $0.append("enqueue") }
                return .accepted(frameID: frame.id)
            },
            flush: { _ in order.withValue { $0.append("flush") } },
            close: { _, _ in order.withValue { $0.append("close") } }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually { captureGate.requestCount == 1 }

        await harness.service.stopCapture(bundleIdentifier: harness.config.bundleIdentifier)
        await Task.yield()
        XCTAssertFalse(order.value.contains("close"), "metadata must remain open while frame acquisition is draining")

        await captureGate.resumeNext(returning: Self.makeImage())
        try await eventually {
            collector.events.contains {
                if case .sessionClosed = $0 { return true }
                return false
            }
        }
        XCTAssertEqual(order.value, ["enqueue", "flush", "close"])
    }

    func testFrameAcquisitionNeverExceedsConfiguredConcurrency() async throws {
        let clock = TestClock<Duration>()
        let captureGate = CaptureGate()
        let enqueuedCount = Locked(0)
        let windows = (1 ... 5).map { number in
            CapturableWindow(
                systemWindowID: number,
                title: "Window \(number)",
                frame: CGRect(x: CGFloat(number * 10), y: CGFloat(number * 10), width: 800, height: 600),
                layer: 0,
                isOnScreen: true
            )
        }
        let harness = makeHarness(
            clock: clock,
            windows: { _ in windows },
            capture: { _ in try await captureGate.next() },
            enqueue: { frame in
                enqueuedCount.withValue { $0 += 1 }
                return .accepted(frameID: frame.id)
            }
        )
        let stream = await harness.service.start()
        let task = Task { for await _ in stream {} }
        defer { task.cancel() }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await harness.service.applyWhitelist([harness.config])

        try await eventually { captureGate.requestCount == 2 }
        for expectedRequestCount in 3 ... 5 {
            await captureGate.resumeNext(returning: Self.makeImage())
            try await eventually { captureGate.requestCount == expectedRequestCount }
        }
        await captureGate.resumeNext(returning: Self.makeImage())
        await captureGate.resumeNext(returning: Self.makeImage())
        try await eventually { enqueuedCount.value == 5 }
        XCTAssertEqual(captureGate.maximumActiveCount, 2)
    }

    func testEncodingOptionsAreFrozenForEveryFrameInCycle() async throws {
        let clock = TestClock<Duration>()
        let captureGate = CaptureGate()
        let selectedOptions = Locked(CaptureEncodingOptions(format: .heic, heicQuality: 0.61))
        let envelopes = Locked<[CapturedFrameEnvelope]>([])
        let windows = [
            CapturableWindow(
                systemWindowID: 1,
                title: "First",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                layer: 0,
                isOnScreen: true
            ),
            CapturableWindow(
                systemWindowID: 2,
                title: "Second",
                frame: CGRect(x: 20, y: 20, width: 800, height: 600),
                layer: 0,
                isOnScreen: true
            ),
        ]
        let harness = makeHarness(
            clock: clock,
            encodingOptions: { selectedOptions.value },
            windows: { _ in windows },
            capture: { _ in try await captureGate.next() },
            enqueue: { envelope in
                envelopes.withValue { $0.append(envelope) }
                return .accepted(frameID: envelope.id)
            }
        )
        let stream = await harness.service.start()
        let task = Task { for await _ in stream {} }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually { captureGate.requestCount == 2 }

        selectedOptions.withValue { $0 = CaptureEncodingOptions(format: .png, heicQuality: 1) }
        await captureGate.resumeNext(returning: Self.makeImage())
        await captureGate.resumeNext(returning: Self.makeImage())
        try await eventually { envelopes.value.count == 2 }
        XCTAssertEqual(envelopes.value.map(\.encodingOptions), [
            CaptureEncodingOptions(format: .heic, heicQuality: 0.61),
            CaptureEncodingOptions(format: .heic, heicQuality: 0.61),
        ])
    }

    func testStorageDegradationPausesAndResumeReanchorsWithoutImmediateCapture() async throws {
        let clock = TestClock<Duration>()
        let storageEvents = StreamPipe<StorageCoordinatorEvent>()
        let requestCount = Locked(0)
        let harness = makeHarness(
            clock: clock,
            storageEvents: storageEvents,
            windows: { _ in
                requestCount.withValue { $0 += 1 }
                return []
            }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually { requestCount.value == 1 }

        storageEvents.yield(.storageDegraded(.queueFull(capacity: 3)))
        try await eventually {
            collector.events.contains {
                guard case let .sessionUpdated(snapshot) = $0 else { return false }
                return snapshot.pauseReason == .storageUnavailable(.queueFull(capacity: 3))
            }
        }
        await clock.advance(by: .seconds(60))
        XCTAssertEqual(requestCount.value, 1)

        storageEvents.yield(.storageResumed)
        try await eventually {
            collector.events.contains {
                if case .storageResumed = $0 { return true }
                return false
            }
        }
        XCTAssertEqual(requestCount.value, 1, "resume must re-anchor rather than capture immediately")
        await clock.advance(by: .seconds(9))
        XCTAssertEqual(requestCount.value, 1)
        await clock.advance(by: .seconds(1))
        try await eventually { requestCount.value == 2 }
    }
}
