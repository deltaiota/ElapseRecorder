import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

final class CaptureEngineFeatureWindowsTests: CaptureEngineFeatureTestCase {
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
}
