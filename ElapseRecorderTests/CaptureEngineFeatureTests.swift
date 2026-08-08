import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class CaptureEngineFeatureTests: XCTestCase {
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

    func testAutoWhitelistStartsAndTerminationClosesSession() async throws {
        let clock = TestClock<Duration>()
        let workspaceEvents = StreamPipe<WorkspaceEvent>()
        let closedSessionIDs = Locked<[UUID]>([])
        let harness = makeHarness(
            clock: clock,
            workspaceEvents: workspaceEvents,
            windows: { _ in [] },
            close: { sessionID, _ in closedSessionIDs.withValue { $0.append(sessionID) } }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }

        await harness.service.applyWhitelist([harness.config])
        try await eventually {
            collector.events.contains {
                if case .sessionOpened = $0 { return true }
                return false
            }
        }
        let openedID = try XCTUnwrap(collector.events.compactMap { event -> UUID? in
            guard case let .sessionOpened(snapshot) = event else { return nil }
            return snapshot.handle.sessionID
        }.first)

        workspaceEvents.yield(.terminated(harness.application))
        try await eventually {
            collector.events.contains {
                guard case let .sessionClosed(handle, _) = $0 else { return false }
                return handle.sessionID == openedID
            }
        }
        XCTAssertEqual(closedSessionIDs.value, [openedID])
    }

    func testManualWhitelistWaitsForExplicitStart() async throws {
        let clock = TestClock<Duration>()
        let openCount = Locked(0)
        let harness = makeHarness(
            clock: clock,
            open: { _ in openCount.withValue { $0 += 1 } },
            windows: { _ in [] }
        )
        var manual = harness.config
        manual.captureMode = .manual
        manual.isEnabled = false
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([manual])

        try await eventually {
            collector.events.contains {
                guard case let .runningApplicationsChanged(applications) = $0 else { return false }
                return applications.contains(harness.application)
            }
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(openCount.value, 0)

        await harness.service.startCapture(bundleIdentifier: manual.bundleIdentifier)
        try await eventually { openCount.value == 1 }
        try await eventually {
            collector.events.contains {
                if case .sessionOpened = $0 { return true }
                return false
            }
        }
    }

    func testPauseAndResumeKeepSessionOpenAndReanchorSchedule() async throws {
        let clock = TestClock<Duration>()
        let requestCount = Locked(0)
        let closeCount = Locked(0)
        let harness = makeHarness(
            clock: clock,
            windows: { _ in
                requestCount.withValue { $0 += 1 }
                return []
            },
            close: { _, _ in closeCount.withValue { $0 += 1 } }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually { requestCount.value == 1 }

        await harness.service.pauseCapture(bundleIdentifier: harness.config.bundleIdentifier)
        try await eventually {
            collector.events.contains {
                guard case let .sessionUpdated(snapshot) = $0 else { return false }
                return snapshot.pauseReason == .user
            }
        }
        await clock.advance(by: .seconds(30))
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(closeCount.value, 0)

        let resumeEventOffset = collector.events.count
        await harness.service.resumeCapture(bundleIdentifier: harness.config.bundleIdentifier)
        try await eventually {
            collector.events.dropFirst(resumeEventOffset).contains {
                guard case let .sessionUpdated(snapshot) = $0 else { return false }
                return snapshot.pauseReason == nil
            }
        }
        await clock.advance(by: .seconds(9))
        XCTAssertEqual(requestCount.value, 1)
        await clock.advance(by: .seconds(1))
        try await eventually { requestCount.value == 2 }
        XCTAssertEqual(closeCount.value, 0)
    }

    func testWindowRegistryKeepsStableNumbersAndTitleHistory() async throws {
        let clock = TestClock<Duration>()
        let cycles = Locked([
            [
                Self.window(id: 10, title: "Untitled"),
                Self.window(id: 20, title: "Second"),
            ],
            [
                Self.window(id: 10, title: "Notes.txt"),
                Self.window(id: 20, title: "Second"),
                Self.window(id: 30, title: "Third"),
            ],
        ])
        let harness = makeHarness(
            clock: clock,
            windows: { _ in cycles.withValue { $0.removeFirst() } }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually {
            collector.events.contains {
                guard case let .sessionUpdated(snapshot) = $0 else { return false }
                return snapshot.windowsBySystemID.count == 2 && !snapshot.isCaptureInFlight
            }
        }

        await clock.advance(by: .seconds(10))
        try await eventually {
            collector.events.contains {
                guard case let .sessionUpdated(snapshot) = $0 else { return false }
                return snapshot.windowsBySystemID.count == 3 && !snapshot.isCaptureInFlight
            }
        }
        let snapshot = try XCTUnwrap(collector.events.compactMap { event -> RecordingSessionSnapshot? in
            guard case let .sessionUpdated(snapshot) = event,
                  snapshot.windowsBySystemID.count == 3,
                  !snapshot.isCaptureInFlight
            else { return nil }
            return snapshot
        }.last)
        XCTAssertEqual(snapshot.windowsBySystemID[10]?.displayNumber, 1)
        XCTAssertEqual(snapshot.windowsBySystemID[20]?.displayNumber, 2)
        XCTAssertEqual(snapshot.windowsBySystemID[30]?.displayNumber, 3)
        XCTAssertEqual(snapshot.nextWindowNumber, 4)
        XCTAssertEqual(snapshot.windowsBySystemID[10]?.titleHistory.map(\.title), ["Untitled", "Notes.txt"] as [String?])
    }

    func testWindowFilteringExcludesAttachedSheetsAndStageManagerWindows() async throws {
        let clock = TestClock<Duration>()
        let main = Self.window(id: 1, title: "Document", frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let sheet = Self.window(id: 2, title: "Open", frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        var stowed = Self.window(id: 3, title: "Stowed", frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        stowed.isStageManagerStowed = true
        var offscreen = Self.window(id: 4, title: "Hidden")
        offscreen.isOnScreen = false
        let stowedWindow = stowed
        let offscreenWindow = offscreen
        let other = Self.window(id: 5, title: "Other", frame: CGRect(x: 1100, y: 0, width: 500, height: 500))
        let harness = makeHarness(
            clock: clock,
            windows: { _ in [main, sheet, stowedWindow, offscreenWindow, other] }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually {
            collector.events.contains {
                guard case let .sessionUpdated(snapshot) = $0 else { return false }
                return Set(snapshot.windowsBySystemID.keys) == Set([1, 5]) && !snapshot.isCaptureInFlight
            }
        }
        let snapshot = try XCTUnwrap(collector.events.compactMap { event -> RecordingSessionSnapshot? in
            guard case let .sessionUpdated(snapshot) = event,
                  Set(snapshot.windowsBySystemID.keys) == Set([1, 5])
            else { return nil }
            return snapshot
        }.last)
        XCTAssertEqual(snapshot.windowsBySystemID[1]?.displayNumber, 1)
        XCTAssertEqual(snapshot.windowsBySystemID[5]?.displayNumber, 2)
    }

    func testUnavailableSpanExtendsOneStableRecordAcrossCycles() async throws {
        let clock = TestClock<Duration>()
        let cycles = Locked([
            [Self.window(id: 1, title: "Document")],
            [],
            [],
        ])
        let records = Locked<[CaptureUnavailableRecord]>([])
        let harness = makeHarness(
            clock: clock,
            recordUnavailable: { record in records.withValue { $0.append(record) } },
            windows: { _ in cycles.withValue { $0.removeFirst() } }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually {
            collector.events.contains {
                guard case let .sessionUpdated(snapshot) = $0 else { return false }
                return snapshot.windowsBySystemID.count == 1 && !snapshot.isCaptureInFlight
            }
        }

        await clock.advance(by: .seconds(10))
        try await eventually { records.value.count == 1 }
        await clock.advance(by: .seconds(10))
        try await eventually { records.value.count == 2 }

        let first = records.value[0]
        let second = records.value[1]
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.startedAt, second.startedAt)
        XCTAssertEqual(first.startedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(first.endedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(second.endedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(first.reason, .windowMinimized)
        XCTAssertEqual(second.reason, .windowMinimized)
    }

    func testDuplicateManualStartsOpenOnlyOneSession() async throws {
        let clock = TestClock<Duration>()
        let openCount = Locked(0)
        let harness = makeHarness(
            clock: clock,
            open: { _ in openCount.withValue { $0 += 1 } },
            windows: { _ in [] }
        )
        var manual = harness.config
        manual.captureMode = .manual
        manual.isEnabled = false
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([manual])
        await harness.service.startCapture(bundleIdentifier: manual.bundleIdentifier)
        await harness.service.startCapture(bundleIdentifier: manual.bundleIdentifier)
        try await eventually {
            collector.events.contains {
                if case .sessionOpened = $0 { return true }
                return false
            }
        }
        await harness.service.startCapture(bundleIdentifier: manual.bundleIdentifier)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(openCount.value, 1)
        XCTAssertEqual(collector.events.filter {
            if case .sessionOpened = $0 { return true }
            return false
        }.count, 1)
    }

    func testOpenFailureReleasesSlotForExplicitRetry() async throws {
        let clock = TestClock<Duration>()
        let openCount = Locked(0)
        let harness = makeHarness(
            clock: clock,
            open: { _ in
                let attempt = openCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                if attempt == 1 { throw RecordingServiceTestError.openFailed }
            },
            windows: { _ in [] }
        )
        var manual = harness.config
        manual.captureMode = .manual
        manual.isEnabled = false
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([manual])
        await harness.service.startCapture(bundleIdentifier: manual.bundleIdentifier)
        try await eventually {
            collector.events.contains {
                if case .diagnostic(.failure) = $0 { return true }
                return false
            }
        }
        XCTAssertFalse(collector.events.contains {
            if case .sessionOpened = $0 { return true }
            return false
        })

        await harness.service.startCapture(bundleIdentifier: manual.bundleIdentifier)
        try await eventually {
            collector.events.contains {
                guard case let .sessionOpened(snapshot) = $0 else { return false }
                return snapshot.handle.generation == 2
            }
        }
        XCTAssertEqual(openCount.value, 2)
    }

    func testDeniedPermissionDoesNotConsumePendingManualStart() async {
        let clock = TestClock<Duration>()
        let permissionStatus = Locked(CapturePermissionStatus.denied)
        let openCount = Locked(0)
        let harness = makeHarness(
            clock: clock,
            permission: CapturePermissionClient(
                status: { permissionStatus.value },
                request: { permissionStatus.value }
            ),
            open: { _ in openCount.withValue { $0 += 1 } },
            windows: { _ in [] }
        )
        var manual = harness.config
        manual.captureMode = .manual
        manual.isEnabled = false
        let stream = await harness.service.start()
        let task = Task { for await _ in stream {} }
        defer { task.cancel() }
        await harness.service.applyWhitelist([manual])

        await harness.service.startCapture(bundleIdentifier: manual.bundleIdentifier)
        await harness.service.registerRunningApplication(harness.application)
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        XCTAssertEqual(openCount.value, 0)
    }

    func testAutomaticOpenRetriesAfterTransientFailure() async throws {
        let clock = TestClock<Duration>()
        let openCount = Locked(0)
        let harness = makeHarness(
            clock: clock,
            open: { _ in
                let attempt = openCount.withValue { count -> Int in
                    count += 1
                    return count
                }
                if attempt == 1 { throw RecordingServiceTestError.openFailed }
            },
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
            collector.events.contains {
                if case .diagnostic(.failure) = $0 { return true }
                return false
            }
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        await clock.advance(by: .seconds(1))
        try await eventually {
            collector.events.contains {
                if case .sessionOpened = $0 { return true }
                return false
            }
        }
        XCTAssertEqual(openCount.value, 2)
    }

    func testCloseRetriesBeforeReplacementGenerationStarts() async throws {
        let clock = TestClock<Duration>()
        let workspaceEvents = StreamPipe<WorkspaceEvent>()
        let closeCount = Locked(0)
        let harness = makeHarness(
            clock: clock,
            workspaceEvents: workspaceEvents,
            windows: { _ in [] },
            close: { _, _ in
                let attempt = closeCount.withValue { count -> Int in
                    count += 1
                    return count
                }
                if attempt == 1 { throw RecordingServiceTestError.closeFailed }
            }
        )
        let collector = EventCollector()
        let stream = await harness.service.start()
        let task = Task { for await event in stream {
            collector.append(event)
        } }
        defer { task.cancel() }
        await harness.service.applyWhitelist([harness.config])
        try await eventually { Self.sessionOpenedCount(in: collector.events) == 1 }

        let replacement = RunningApplication(
            bundleIdentifier: harness.application.bundleIdentifier,
            displayName: harness.application.displayName,
            processIdentifier: 202
        )
        workspaceEvents.yield(.launched(replacement))
        try await eventually { closeCount.value == 1 }
        XCTAssertEqual(Self.sessionOpenedCount(in: collector.events), 1)

        await clock.advance(by: .seconds(1))
        try await eventually { Self.sessionOpenedCount(in: collector.events) == 2 }
        XCTAssertEqual(closeCount.value, 2)
    }

    @MainActor
    func testReducerIgnoresStaleGenerationSnapshotForReplacementSession() async throws {
        let app = RunningApplication(bundleIdentifier: "com.example.Editor", displayName: "Editor", processIdentifier: 2)
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 10,
            isEnabled: true
        )
        let replacementSession = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: 2,
            startedAt: .init(timeIntervalSince1970: 2)
        )
        var state = CaptureEngineFeature.State()
        state.activeSessions[app.bundleIdentifier] = .init(
            application: app,
            config: config,
            session: replacementSession,
            generation: 2
        )
        let staleSession = try CaptureSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            processIdentifier: 1,
            startedAt: .init(timeIntervalSince1970: 1)
        )
        let staleSnapshot = RecordingSessionSnapshot(
            handle: RecordingSessionHandle(
                sessionID: staleSession.id,
                bundleIdentifier: app.bundleIdentifier,
                processIdentifier: 1,
                generation: 1
            ),
            application: RunningApplication(
                bundleIdentifier: app.bundleIdentifier,
                displayName: app.displayName,
                processIdentifier: 1
            ),
            config: config,
            session: staleSession,
            nextWindowNumber: 99,
            windowsBySystemID: [:],
            isCaptureInFlight: true,
            captureUnavailableReason: .windowMinimized,
            pauseReason: nil
        )
        let store = TestStore(initialState: state) { CaptureEngineFeature() }

        await store.send(.recordingServiceEvent(.sessionUpdated(staleSnapshot)))
        XCTAssertEqual(store.state.activeSessions[app.bundleIdentifier]?.session.id, replacementSession.id)
        XCTAssertEqual(store.state.activeSessions[app.bundleIdentifier]?.generation, 2)
        XCTAssertEqual(store.state.activeSessions[app.bundleIdentifier]?.nextWindowNumber, 1)
    }

    private static func sessionOpenedCount(in events: [RecordingServiceEvent]) -> Int {
        events.count { event in
            if case .sessionOpened = event { return true }
            return false
        }
    }

    private func makeHarness(
        clock: TestClock<Duration>,
        storageEvents: StreamPipe<StorageCoordinatorEvent> = StreamPipe(),
        workspaceEvents: StreamPipe<WorkspaceEvent> = StreamPipe(),
        permission: CapturePermissionClient = CapturePermissionClient(status: { .authorized }, request: { .authorized }),
        encodingOptions: @escaping @Sendable () -> CaptureEncodingOptions = { .defaultValue },
        open: @escaping @Sendable (CaptureSession) async throws -> Void = { _ in },
        recordUnavailable: @escaping @Sendable (CaptureUnavailableRecord) async throws -> Void = { _ in },
        windows: @escaping @Sendable (RunningApplication) async throws -> [CapturableWindow],
        capture: @escaping @Sendable (Int) async throws -> CapturedImage = { _ in CaptureEngineFeatureTests.makeImage() },
        enqueue: @escaping @Sendable (CapturedFrameEnvelope) async -> StorageEnqueueResult = { .accepted(frameID: $0.id) },
        flush: @escaping @Sendable (RecordingSessionHandle) async throws -> Void = { _ in },
        close: @escaping @Sendable (UUID, Date) async throws -> Void = { _, _ in }
    ) -> Harness {
        let app = RunningApplication(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            processIdentifier: 101
        )
        let config = WhitelistedAppConfig(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            captureInterval: 10,
            isEnabled: true
        )
        var persistence = PersistenceClient.unimplemented
        persistence.openSession = open
        persistence.closeSession = close
        persistence.closeOpenSessions = { _ in 0 }
        persistence.upsertWindow = { _ in }
        persistence.recordCaptureUnavailable = recordUnavailable

        var storage = StorageCoordinatorClient.testValue
        storage.events = { storageEvents.stream }
        storage.enqueue = enqueue
        storage.flushSession = flush
        storage.recover = {}
        var preferences = CapturePreferencesClient.testValue
        preferences.encodingOptions = encodingOptions

        let idSequence = IDSequence()
        let clockOrigin = clock.now
        let service = RecordingService(
            dependencies: .init(
                workspace: WorkspaceClient(
                    runningApplications: { [app] },
                    events: { workspaceEvents.stream }
                ),
                permission: permission,
                screenCapture: ScreenCaptureClient(windows: windows, capture: capture),
                persistence: persistence,
                storage: storage,
                date: DateClient(now: {
                    let elapsed = clockOrigin.duration(to: clock.now)
                    return Date(timeIntervalSince1970: TimeInterval(elapsed.components.seconds))
                }),
                ids: IDGeneratorClient(uuid: { idSequence.next() }),
                perceptualHash: PerceptualHashClient(hash: { _ in 0x1234 }),
                preferences: preferences,
                logger: LoggingClient(log: { _, _, _ in }),
                clock: RecordingServiceClock(
                    now: { clockOrigin.duration(to: clock.now) },
                    sleep: { try await clock.sleep(for: $0) }
                ),
                maximumConcurrentFrameAcquisitions: 2
            )
        )
        return Harness(service: service, config: config, application: app)
    }

    private func eventually(
        _ predicate: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 2000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    private static func window(
        id: Int,
        title: String?,
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> CapturableWindow {
        CapturableWindow(
            systemWindowID: id,
            title: title,
            frame: frame,
            layer: 0,
            isOnScreen: true
        )
    }

    private static func makeImage() -> CapturedImage {
        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return CapturedImage(cgImage: context.makeImage()!)
    }
}

private struct Harness {
    var service: RecordingService
    var config: WhitelistedAppConfig
    var application: RunningApplication
}

private enum RecordingServiceTestError: Error {
    case openFailed
    case closeFailed
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordingServiceEvent] = []

    var events: [RecordingServiceEvent] {
        lock.withLock { storage }
    }

    func append(_ event: RecordingServiceEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class StreamPipe<Element: Sendable>: @unchecked Sendable {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() {
        let pair = AsyncStream<Element>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ element: Element) {
        continuation.yield(element)
    }
}

private final class WindowGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<[CapturableWindow], Error>] = []
    private var count = 0

    var requestCount: Int {
        lock.withLock { count }
    }

    func next() async throws -> [CapturableWindow] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                count += 1
                continuations.append(continuation)
            }
        }
    }

    func resumeNext(returning windows: [CapturableWindow]) {
        let continuation = lock.withLock { continuations.removeFirst() }
        continuation.resume(returning: windows)
    }
}

private final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<CapturedImage, Error>] = []
    private var count = 0
    private var activeCount = 0
    private var maximumActive = 0

    var requestCount: Int {
        lock.withLock { count }
    }

    var maximumActiveCount: Int {
        lock.withLock { maximumActive }
    }

    func next() async throws -> CapturedImage {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                count += 1
                activeCount += 1
                maximumActive = max(maximumActive, activeCount)
                continuations.append(continuation)
            }
        }
    }

    func resumeNext(returning image: CapturedImage) async {
        for _ in 0 ..< 2000 {
            if let continuation = lock.withLock({ () -> CheckedContinuation<CapturedImage, Error>? in
                guard !continuations.isEmpty else { return nil }
                activeCount -= 1
                return continuations.removeFirst()
            }) {
                continuation.resume(returning: image)
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for an active capture continuation")
    }
}

private final class IDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UUID {
        lock.withLock {
            value += 1
            let suffix = String(format: "%012llu", value)
            return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
        }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    @discardableResult
    func withValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.withLock { operation(&storage) }
    }
}
