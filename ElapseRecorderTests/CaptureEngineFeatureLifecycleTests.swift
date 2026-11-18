import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class CaptureEngineFeatureLifecycleTests: CaptureEngineFeatureTestCase {
    func testFrontmostWhitelistedAppSuspendsCompactionUntilAnotherAppActivates() async throws {
        let clock = TestClock<Duration>()
        let workspaceEvents = StreamPipe<WorkspaceEvent>()
        let suspensionStates = Locked<[Bool]>([])
        let frontmost = RunningApplication(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            processIdentifier: 101
        )
        let harness = makeHarness(
            clock: clock,
            workspaceEvents: workspaceEvents,
            frontmostApplication: { frontmost },
            windows: { _ in [] },
            setCompactionSuspended: { suspended in
                suspensionStates.withValue { $0.append(suspended) }
            }
        )

        _ = await harness.service.start()
        try await eventually { suspensionStates.value.last == true }
        await harness.service.applyWhitelist([harness.config])
        XCTAssertEqual(suspensionStates.value.last, true)

        workspaceEvents.yield(.activated(RunningApplication(
            bundleIdentifier: "com.example.Other",
            displayName: "Other",
            processIdentifier: 202
        )))
        try await eventually { suspensionStates.value.last == false }
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
}
