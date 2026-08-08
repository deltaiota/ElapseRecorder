import ComposableArchitecture
import Foundation

struct CaptureEngineFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var whitelist: [String: WhitelistedAppConfig] = [:]
        var runningApplications: [String: RunningApplication] = [:]
        var activeSessions: [String: ActiveSession] = [:]
        var permissionStatus: CapturePermissionStatus = .notDetermined
        var lastError: String?
        var lastWorkspaceEvent: WorkspaceEvent?
        var recentDiagnostics: [CaptureDiagnostic] = []
        var storageDegradation: StorageDegradation?
        var schedulerDeadlineMissCount = 0

        struct ActiveSession: Equatable {
            var application: RunningApplication
            var config: WhitelistedAppConfig
            var session: CaptureSession
            var generation: UInt64 = 0
            var nextWindowNumber: Int = 1
            var windowsBySystemID: [Int: MonitoredWindow] = [:]
            var isCaptureInFlight = false
            var isCapturePending = false
            var captureUnavailableReason: CaptureUnavailableReason?
            var unavailableRecordID: UUID?
            var unavailableStartedAt: Date?
            var pauseReason: RecordingPauseReason?

            init(
                application: RunningApplication,
                config: WhitelistedAppConfig,
                session: CaptureSession,
                generation: UInt64 = 0,
                nextWindowNumber: Int = 1,
                windowsBySystemID: [Int: MonitoredWindow] = [:],
                isCaptureInFlight: Bool = false,
                isCapturePending: Bool = false,
                captureUnavailableReason: CaptureUnavailableReason? = nil,
                unavailableRecordID: UUID? = nil,
                unavailableStartedAt: Date? = nil,
                pauseReason: RecordingPauseReason? = nil
            ) {
                self.application = application
                self.config = config
                self.session = session
                self.generation = generation
                self.nextWindowNumber = nextWindowNumber
                self.windowsBySystemID = windowsBySystemID
                self.isCaptureInFlight = isCaptureInFlight
                self.isCapturePending = isCapturePending
                self.captureUnavailableReason = captureUnavailableReason
                self.unavailableRecordID = unavailableRecordID
                self.unavailableStartedAt = unavailableStartedAt
                self.pauseReason = pauseReason
            }
        }
    }

    enum Action: Equatable {
        case task
        case requestPermissionButtonTapped
        case refreshRunningApplications
        case captureStart(String)
        case captureStop(String)
        case capturePause(String)
        case captureResume(String)
        case staleOpenSessionsClosed(Int)
        case staleOpenSessionCloseFailed(String)
        case whitelistUpdated([WhitelistedAppConfig])
        case runningApplicationsLoaded([RunningApplication])
        case runningApplicationRegistered(RunningApplication)
        case workspaceEvent(WorkspaceEvent)
        case permissionResolved(CapturePermissionStatus, RunningApplication?)
        case sessionOpened(CaptureSession, RunningApplication)
        case sessionOpenFailed(String?, UUID?, String)
        case captureTick(String)
        case windowsFailed(String, String)
        case windowsLoaded(String, [CapturableWindow])
        case screenshotFailed(String, String)
        case screenshotRecorded(ScreenshotRecord)
        case captureUnavailableRecorded(CaptureUnavailableRecord)
        case captureCycleFinished(String)
        case sessionClosed(String)
        case recordingServiceEvent(RecordingServiceEvent)
    }

    @Dependency(\.recordingServiceClient) private var recordingService

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                let recordingService = recordingService
                return .run { send in
                    let events = await recordingService.start()
                    for await event in events {
                        await send(.recordingServiceEvent(event))
                    }
                }
                .cancellable(id: RecordingServiceSubscriptionID(), cancelInFlight: true)

            case .requestPermissionButtonTapped:
                let recordingService = recordingService
                return .run { _ in await recordingService.requestPermission() }

            case .refreshRunningApplications:
                let recordingService = recordingService
                return .run { _ in await recordingService.refreshRunningApplications() }

            case let .captureStart(bundleIdentifier):
                let recordingService = recordingService
                return .run { _ in await recordingService.startCapture(bundleIdentifier) }

            case let .captureStop(bundleIdentifier):
                let recordingService = recordingService
                return .run { _ in await recordingService.stopCapture(bundleIdentifier) }

            case let .capturePause(bundleIdentifier):
                let recordingService = recordingService
                return .run { _ in await recordingService.pauseCapture(bundleIdentifier) }

            case let .captureResume(bundleIdentifier):
                let recordingService = recordingService
                return .run { _ in await recordingService.resumeCapture(bundleIdentifier) }

            case let .whitelistUpdated(configs):
                state.whitelist = Dictionary(
                    configs.map { ($0.bundleIdentifier, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )
                let recordingService = recordingService
                return .run { _ in await recordingService.applyWhitelist(configs) }

            case let .runningApplicationRegistered(application):
                state.runningApplications[application.bundleIdentifier] = application
                let recordingService = recordingService
                return .run { _ in await recordingService.registerRunningApplication(application) }

            case let .recordingServiceEvent(event):
                return reduceServiceEvent(event, state: &state)

            // These actions remain the public feature event surface used by AppFeature and
            // existing views. All lifecycle and capture work has already happened in the actor.
            case let .permissionResolved(status, _):
                state.permissionStatus = status
                if status == .authorized {
                    state.clearPermissionDeniedError()
                } else if status == .denied {
                    state.recordDiagnostic(.permissionRequired)
                }
                return .none

            case let .runningApplicationsLoaded(applications):
                state.runningApplications = Dictionary(
                    applications.map { ($0.bundleIdentifier, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )
                return .none

            case let .workspaceEvent(event):
                state.lastWorkspaceEvent = event
                switch event {
                case let .launched(application), let .activated(application):
                    state.runningApplications[application.bundleIdentifier] = application
                case let .terminated(application):
                    if state.runningApplications[application.bundleIdentifier]?.processIdentifier == application.processIdentifier {
                        state.runningApplications[application.bundleIdentifier] = nil
                    }
                }
                return .none

            case let .sessionOpened(session, application):
                guard state.activeSessions[application.bundleIdentifier]?.session.id == session.id else {
                    return .none
                }
                return .none

            case let .sessionOpenFailed(bundleIdentifier, sessionID, message):
                if let bundleIdentifier,
                   let sessionID,
                   state.activeSessions[bundleIdentifier]?.session.id == sessionID
                {
                    state.activeSessions[bundleIdentifier] = nil
                }
                state.recordDiagnostic(.failure(message))
                return .none

            case let .screenshotRecorded(record):
                if let bundleIdentifier = state.activeSessions.first(where: { $0.value.session.id == record.sessionID })?.key {
                    state.activeSessions[bundleIdentifier]?.captureUnavailableReason = nil
                }
                return .none

            case let .captureUnavailableRecorded(record):
                if let bundleIdentifier = state.activeSessions.first(where: { $0.value.session.id == record.sessionID })?.key {
                    state.activeSessions[bundleIdentifier]?.captureUnavailableReason = record.reason
                }
                return .none

            case let .staleOpenSessionsClosed(count):
                if count > 0 {
                    state.recordDiagnostic(.closedStaleSessions(count: count))
                }
                return .none

            case let .staleOpenSessionCloseFailed(message),
                 let .windowsFailed(_, message),
                 let .screenshotFailed(_, message):
                state.recordDiagnostic(.failure(message))
                return .none

            case .captureTick, .windowsLoaded, .captureCycleFinished, .sessionClosed:
                return .none
            }
        }
    }

    private func reduceServiceEvent(
        _ event: RecordingServiceEvent,
        state: inout State
    ) -> Effect<Action> {
        switch event {
        case let .permissionChanged(status):
            return .send(.permissionResolved(status, nil))

        case let .runningApplicationsChanged(applications):
            return .send(.runningApplicationsLoaded(applications))

        case let .workspaceEvent(event):
            return .send(.workspaceEvent(event))

        case let .sessionOpened(snapshot):
            state.activeSessions[snapshot.handle.bundleIdentifier] = activeSession(from: snapshot)
            return .send(.sessionOpened(snapshot.session, snapshot.application))

        case let .sessionUpdated(snapshot):
            guard state.activeSessions[snapshot.handle.bundleIdentifier]?.session.id == snapshot.handle.sessionID else {
                return .none
            }
            state.activeSessions[snapshot.handle.bundleIdentifier] = activeSession(from: snapshot)
            return .none

        case let .sessionClosed(handle, _):
            if state.activeSessions[handle.bundleIdentifier]?.session.id == handle.sessionID {
                state.activeSessions[handle.bundleIdentifier] = nil
            }
            return .send(.sessionClosed(handle.bundleIdentifier))

        case let .frameCommitted(_, record):
            return .send(.screenshotRecorded(record))

        case .segmentCommitted:
            return .none

        case let .captureUnavailableRecorded(_, record):
            return .send(.captureUnavailableRecorded(record))

        case let .diagnostic(diagnostic):
            state.recordDiagnostic(diagnostic)
            return .none

        case let .storageDegraded(degradation):
            state.storageDegradation = degradation
            return .none

        case .storageResumed:
            state.storageDegradation = nil
            return .none

        case .schedulerDeadlineMissed:
            state.schedulerDeadlineMissCount += 1
            return .none
        }
    }

    private func activeSession(from snapshot: RecordingSessionSnapshot) -> State.ActiveSession {
        State.ActiveSession(
            application: snapshot.application,
            config: snapshot.config,
            session: snapshot.session,
            generation: snapshot.handle.generation,
            nextWindowNumber: snapshot.nextWindowNumber,
            windowsBySystemID: snapshot.windowsBySystemID,
            isCaptureInFlight: snapshot.isCaptureInFlight,
            captureUnavailableReason: snapshot.captureUnavailableReason,
            pauseReason: snapshot.pauseReason
        )
    }
}

extension CaptureEngineFeature.State {
    mutating func recordDiagnostic(_ diagnostic: CaptureDiagnostic) {
        lastError = diagnostic.message
        if recentDiagnostics.last != diagnostic {
            recentDiagnostics.append(diagnostic)
        }
        if recentDiagnostics.count > 6 {
            recentDiagnostics.removeFirst(recentDiagnostics.count - 6)
        }
    }

    mutating func clearPermissionDeniedError() {
        if lastError == CaptureEngineError.screenRecordingPermissionDenied.localizedDescription {
            lastError = nil
        }
    }
}

private nonisolated struct RecordingServiceSubscriptionID: Hashable {}
