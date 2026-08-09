import ComposableArchitecture
import Foundation

nonisolated struct RecordingServiceClient {
    var start: @Sendable () async -> AsyncStream<RecordingServiceEvent>
    var applyWhitelist: @Sendable (_ configs: [WhitelistedAppConfig]) async -> Void
    var registerRunningApplication: @Sendable (_ application: RunningApplication) async -> Void
    var startCapture: @Sendable (_ bundleIdentifier: String) async -> Void
    var stopCapture: @Sendable (_ bundleIdentifier: String) async -> Void
    var pauseCapture: @Sendable (_ bundleIdentifier: String) async -> Void
    var resumeCapture: @Sendable (_ bundleIdentifier: String) async -> Void
    var requestPermission: @Sendable () async -> Void
    var refreshRunningApplications: @Sendable () async -> Void
}

extension RecordingServiceClient: DependencyKey {
    static let liveValue = live(dependencies: RecordingService.Dependencies(
        workspace: .liveValue,
        permission: .liveValue,
        screenCapture: .liveValue,
        persistence: .liveValue,
        storage: .liveValue,
        date: .liveValue,
        ids: .liveValue,
        perceptualHash: .liveValue,
        preferences: .liveValue,
        logger: .liveValue
    ))

    nonisolated static func live(dependencies: RecordingService.Dependencies) -> Self {
        let service = RecordingService(dependencies: dependencies)
        return Self(
            start: { await service.start() },
            applyWhitelist: { await service.applyWhitelist($0) },
            registerRunningApplication: { await service.registerRunningApplication($0) },
            startCapture: { await service.startCapture(bundleIdentifier: $0) },
            stopCapture: { await service.stopCapture(bundleIdentifier: $0) },
            pauseCapture: { await service.pauseCapture(bundleIdentifier: $0) },
            resumeCapture: { await service.resumeCapture(bundleIdentifier: $0) },
            requestPermission: { await service.requestPermission() },
            refreshRunningApplications: { await service.refreshRunningApplications() }
        )
    }

    static let testValue = Self(
        start: { AsyncStream { $0.finish() } },
        applyWhitelist: { _ in },
        registerRunningApplication: { _ in },
        startCapture: { _ in },
        stopCapture: { _ in },
        pauseCapture: { _ in },
        resumeCapture: { _ in },
        requestPermission: {},
        refreshRunningApplications: {}
    )
}

extension DependencyValues {
    var recordingServiceClient: RecordingServiceClient {
        get { self[RecordingServiceClient.self] }
        set { self[RecordingServiceClient.self] = newValue }
    }
}
