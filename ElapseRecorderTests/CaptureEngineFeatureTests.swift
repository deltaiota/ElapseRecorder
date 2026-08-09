import ComposableArchitecture
import CoreGraphics
@testable import ElapseRecorder
import Foundation
import XCTest

class CaptureEngineFeatureTestCase: XCTestCase {
    static func sessionOpenedCount(in events: [RecordingServiceEvent]) -> Int {
        events.count { event in
            if case .sessionOpened = event { return true }
            return false
        }
    }

    func makeHarness(
        clock: TestClock<Duration>,
        storageEvents: StreamPipe<StorageCoordinatorEvent> = StreamPipe(),
        workspaceEvents: StreamPipe<WorkspaceEvent> = StreamPipe(),
        permission: CapturePermissionClient = CapturePermissionClient(status: { .authorized }, request: { .authorized }),
        encodingOptions: @escaping @Sendable () -> CaptureEncodingOptions = { .defaultValue },
        open: @escaping @Sendable (CaptureSession) async throws -> Void = { _ in },
        recordUnavailable: @escaping @Sendable (CaptureUnavailableRecord) async throws -> Void = { _ in },
        windows: @escaping @Sendable (RunningApplication) async throws -> [CapturableWindow],
        capture: @escaping @Sendable (Int) async throws -> CapturedImage = { _ in CaptureEngineFeatureTestCase.makeImage() },
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

    func eventually(
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

    static func window(
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

    static func makeImage() -> CapturedImage {
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

struct Harness {
    var service: RecordingService
    var config: WhitelistedAppConfig
    var application: RunningApplication
}

enum RecordingServiceTestError: Error {
    case openFailed
    case closeFailed
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordingServiceEvent] = []

    var events: [RecordingServiceEvent] {
        lock.withLock { storage }
    }

    func append(_ event: RecordingServiceEvent) {
        lock.withLock { storage.append(event) }
    }
}

final class StreamPipe<Element: Sendable>: @unchecked Sendable {
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

final class WindowGate: @unchecked Sendable {
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

final class CaptureGate: @unchecked Sendable {
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

final class IDSequence: @unchecked Sendable {
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

final class Locked<Value>: @unchecked Sendable {
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
