import ComposableArchitecture
@preconcurrency import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

nonisolated struct PersistentWindowCaptureSettings: Equatable, Sendable {
    var width: Int
    var height: Int
    var minimumFrameInterval: TimeInterval
}

private nonisolated struct CapturedPixelBuffer: @unchecked Sendable {
    var value: CVPixelBuffer
}

private nonisolated enum NextFrameDecision: @unchecked Sendable {
    case frame(CapturedPixelBuffer)
    case failure(Error)
    case waiting
}

private final nonisolated class PersistentWindowCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct State {
        var latest: CapturedPixelBuffer?
        var terminalError: Error?
        var waiters: [UUID: CheckedContinuation<CapturedPixelBuffer, Error>] = [:]
    }

    private let state = LockIsolated(State())
    let queue: DispatchQueue

    init(windowID: Int) {
        queue = DispatchQueue(
            label: "d.iota.ElapseRecorder.capture.window-\(windowID)",
            qos: .background,
            autoreleaseFrequency: .workItem
        )
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus),
            status != .complete,
            status != .started,
            status != .idle
        {
            return
        }

        publish(CapturedPixelBuffer(value: pixelBuffer))
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        fail(error)
    }

    func nextFrame() async throws -> CapturedPixelBuffer {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let decision = state.withValue { state -> NextFrameDecision in
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    } else if let latest = state.latest {
                        return .frame(latest)
                    } else if let terminalError = state.terminalError {
                        return .failure(terminalError)
                    } else {
                        state.waiters[id] = continuation
                        return .waiting
                    }
                }
                switch decision {
                case let .frame(frame):
                    continuation.resume(returning: frame)
                case let .failure(error):
                    continuation.resume(throwing: error)
                case .waiting:
                    break
                }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    func currentFrame() -> CapturedPixelBuffer? {
        state.withValue(\.latest)
    }

    func reset() {
        let waiters = state.withValue { state in
            let waiters = Array(state.waiters.values)
            state.latest = nil
            state.terminalError = nil
            state.waiters.removeAll(keepingCapacity: true)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    func fail(_ error: Error) {
        let waiters = state.withValue { state in
            state.terminalError = error
            state.latest = nil
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: true)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func publish(_ frame: CapturedPixelBuffer) {
        let waiters = state.withValue { state in
            state.latest = frame
            state.terminalError = nil
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: true)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: frame)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter = state.withValue { $0.waiters.removeValue(forKey: id) }
        waiter?.resume(throwing: CancellationError())
    }
}

private actor PersistentWindowCaptureStream {
    let processIdentifier: pid_t
    let windowID: Int

    private let output: PersistentWindowCaptureOutput
    private var stream: SCStream?
    private var settings: PersistentWindowCaptureSettings?

    init(processIdentifier: pid_t, windowID: Int) {
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        output = PersistentWindowCaptureOutput(windowID: windowID)
    }

    func capture(window: SCWindow, settings requestedSettings: PersistentWindowCaptureSettings) async throws -> CapturedImage {
        try await prepare(window: window, settings: requestedSettings)
        do {
            let pixelBuffer = (try await nextFrame()).value
            try Task.checkCancellation()
            var image: CGImage?
            let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            guard status == noErr, let image else {
                throw CaptureEngineError.windowCaptureFailed(systemWindowID: windowID)
            }
            return CapturedImage(cgImage: image)
        } catch {
            await stop()
            throw error
        }
    }

    private func nextFrame() async throws -> CapturedPixelBuffer {
        if let frame = output.currentFrame() { return frame }
        let output = self.output
        let windowID = self.windowID
        return try await withThrowingTaskGroup(of: CapturedPixelBuffer.self) { group in
            group.addTask { try await output.nextFrame() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw CaptureEngineError.windowCaptureFailed(systemWindowID: windowID)
            }
            guard let frame = try await group.next() else {
                throw CaptureEngineError.windowCaptureFailed(systemWindowID: windowID)
            }
            group.cancelAll()
            return frame
        }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        settings = nil
        output.fail(CancellationError())
        try? await stream.stopCapture()
    }

    private func prepare(window: SCWindow, settings requestedSettings: PersistentWindowCaptureSettings) async throws {
        if let stream {
            guard settings != requestedSettings else { return }
            do {
                try await stream.updateConfiguration(Self.configuration(requestedSettings))
                output.reset()
                settings = requestedSettings
                return
            } catch {
                await stop()
                throw error
            }
        }

        output.reset()
        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: Self.configuration(requestedSettings),
            delegate: output
        )
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            self.stream = stream
            settings = requestedSettings
            try await stream.startCapture()
        } catch {
            self.stream = nil
            settings = nil
            output.fail(error)
            throw error
        }
    }

    private static func configuration(_ settings: PersistentWindowCaptureSettings) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = settings.width
        configuration.height = settings.height
        configuration.minimumFrameInterval = CMTime(
            seconds: max(1, settings.minimumFrameInterval),
            preferredTimescale: 600
        )
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        return configuration
    }
}

actor PersistentWindowCapturePool {
    private struct Entry {
        var processIdentifier: pid_t
        var stream: PersistentWindowCaptureStream
    }

    private var entries: [Int: Entry] = [:]

    func capture(
        window: SCWindow,
        settings: PersistentWindowCaptureSettings
    ) async throws -> CapturedImage {
        let windowID = Int(window.windowID)
        guard let processIdentifier = window.owningApplication?.processID else {
            throw CaptureEngineError.windowCaptureFailed(systemWindowID: windowID)
        }

        let captureStream: PersistentWindowCaptureStream
        if let entry = entries[windowID], entry.processIdentifier == processIdentifier {
            captureStream = entry.stream
        } else {
            if let replaced = entries.removeValue(forKey: windowID) {
                await replaced.stream.stop()
            }
            let created = PersistentWindowCaptureStream(
                processIdentifier: processIdentifier,
                windowID: windowID
            )
            entries[windowID] = Entry(processIdentifier: processIdentifier, stream: created)
            captureStream = created
        }
        return try await captureStream.capture(window: window, settings: settings)
    }

    func synchronize(processIdentifier: pid_t, windowIDs: Set<Int>) async {
        let staleIDs = entries.compactMap { windowID, entry in
            entry.processIdentifier == processIdentifier && !windowIDs.contains(windowID) ? windowID : nil
        }
        let staleStreams = staleIDs.compactMap { entries.removeValue(forKey: $0)?.stream }
        for stream in staleStreams {
            await stream.stop()
        }
    }

    func release(processIdentifier: pid_t) async {
        let releasedIDs = entries.compactMap { windowID, entry in
            entry.processIdentifier == processIdentifier ? windowID : nil
        }
        let releasedStreams = releasedIDs.compactMap { entries.removeValue(forKey: $0)?.stream }
        for stream in releasedStreams {
            await stream.stop()
        }
    }
}
