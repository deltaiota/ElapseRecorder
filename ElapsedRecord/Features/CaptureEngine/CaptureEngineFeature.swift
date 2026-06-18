import Chronicle
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
        var recentDiagnostics: [String] = []

        struct ActiveSession: Equatable {
            var application: RunningApplication
            var config: WhitelistedAppConfig
            var session: CaptureSession
            var nextWindowNumber: Int = 1
            var windowsBySystemID: [Int: MonitoredWindow] = [:]
            var isCaptureInFlight = false
        }
    }

    enum Action: Equatable {
        case task
        case whitelistUpdated([WhitelistedAppConfig])
        case runningApplicationsLoaded([RunningApplication])
        case workspaceEvent(WorkspaceEvent)
        case permissionResolved(CapturePermissionStatus, RunningApplication?)
        case sessionOpened(CaptureSession, RunningApplication)
        case sessionOpenFailed(String)
        case captureTick(String)
        case windowsFailed(String, String)
        case windowsLoaded(String, [CapturableWindow])
        case screenshotFailed(String, String)
        case screenshotRecorded(ScreenshotRecord)
        case captureCycleFinished(String)
        case sessionClosed(String)
    }

    @Dependency(\.capturePermissionClient) private var permission
    @Dependency(\.capturePreferencesClient) private var preferences
    @Dependency(\.continuousClock) private var clock
    @Dependency(\.dateClient) private var date
    @Dependency(\.fileStorageClient) private var storage
    @Dependency(\.idGeneratorClient) private var ids
    @Dependency(\.imageEncodingClient) private var encoder
    @Dependency(\.loggingClient) private var logger
    @Dependency(\.persistenceClient) private var persistence
    @Dependency(\.screenCaptureClient) private var screenCapture
    @Dependency(\.workspaceClient) private var workspace

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                let permission = permission
                let workspace = workspace

                return .merge(
                    .run { send in
                        await send(.permissionResolved(await permission.status(), nil))
                    },
                    .run { send in
                        await send(.runningApplicationsLoaded(await workspace.runningApplications()))
                    },
                    .run { send in
                        for await event in workspace.events() {
                            await send(.workspaceEvent(event))
                        }
                    }
                )

            case let .whitelistUpdated(configs):
                state.whitelist = Dictionary(
                    configs.map { ($0.bundleIdentifier, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )

                var effects: [Effect<Action>] = []
                for (bundleIdentifier, active) in state.activeSessions {
                    guard let updatedConfig = state.whitelist[bundleIdentifier],
                          updatedConfig.isEnabled
                    else {
                        state.activeSessions[bundleIdentifier] = nil
                        effects.append(closeSession(active, endedAt: date.now()))
                        continue
                    }

                    guard updatedConfig != active.config else { continue }

                    var updatedActive = active
                    updatedActive.config = updatedConfig
                    state.activeSessions[bundleIdentifier] = updatedActive

                    if updatedConfig.sanitizedInterval != active.config.sanitizedInterval {
                        effects.append(
                            captureLoop(
                                bundleIdentifier: bundleIdentifier,
                                interval: updatedConfig.sanitizedInterval
                            )
                        )
                    }
                }

                let startEffects = state.runningApplications.values.map { application in
                    attemptStart(application, state: &state)
                }

                return .merge(effects + startEffects)

            case let .runningApplicationsLoaded(applications):
                state.runningApplications = Dictionary(
                    applications.map { ($0.bundleIdentifier, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )
                return .merge(applications.map { attemptStart($0, state: &state) })

            case let .workspaceEvent(.launched(application)):
                state.runningApplications[application.bundleIdentifier] = application
                return attemptStart(application, state: &state)

            case let .workspaceEvent(.terminated(application)):
                state.runningApplications[application.bundleIdentifier] = nil
                guard let active = state.activeSessions.removeValue(forKey: application.bundleIdentifier) else {
                    return .none
                }
                return closeSession(active, endedAt: date.now())

            case let .workspaceEvent(.activated(application)):
                state.runningApplications[application.bundleIdentifier] = application
                return .none

            case let .permissionResolved(status, application):
                state.permissionStatus = status
                guard status == .authorized, let application else {
                    if status == .denied {
                        state.recordDiagnostic(CaptureEngineError.screenRecordingPermissionDenied.localizedDescription)
                    }
                    return .none
                }
                return attemptStart(application, state: &state)

            case let .sessionOpened(session, application):
                guard let config = state.whitelist[application.bundleIdentifier], config.isEnabled else {
                    return .none
                }

                state.activeSessions[application.bundleIdentifier] = State.ActiveSession(
                    application: application,
                    config: config,
                    session: session
                )

                return captureLoop(bundleIdentifier: application.bundleIdentifier, interval: config.sanitizedInterval)

            case let .sessionOpenFailed(message):
                state.recordDiagnostic(message)
                return .none

            case let .captureTick(bundleIdentifier):
                guard var active = state.activeSessions[bundleIdentifier],
                      !active.isCaptureInFlight
                else {
                    return .none
                }

                active.isCaptureInFlight = true
                state.activeSessions[bundleIdentifier] = active

                let application = active.application
                let screenCapture = screenCapture
                return .run { send in
                    do {
                        let windows = try await screenCapture.windows(application)
                        await send(.windowsLoaded(bundleIdentifier, windows))
                    } catch {
                        await send(.windowsFailed(bundleIdentifier, error.localizedDescription))
                    }
                }

            case let .windowsLoaded(bundleIdentifier, windows):
                guard var active = state.activeSessions[bundleIdentifier] else { return .none }

                let seenAt = date.now()
                var monitoredWindows: [MonitoredWindow] = []

                for window in windows where window.shouldCapture {
                    if var monitoredWindow = active.windowsBySystemID[window.systemWindowID] {
                        monitoredWindow.lastSeenAt = seenAt
                        active.windowsBySystemID[window.systemWindowID] = monitoredWindow
                        monitoredWindows.append(monitoredWindow)
                    } else {
                        let monitoredWindow = MonitoredWindow(
                            id: ids.uuid(),
                            sessionID: active.session.id,
                            systemWindowID: window.systemWindowID,
                            displayNumber: active.nextWindowNumber,
                            label: window.title,
                            firstSeenAt: seenAt,
                            lastSeenAt: seenAt
                        )
                        active.nextWindowNumber += 1
                        active.windowsBySystemID[window.systemWindowID] = monitoredWindow
                        monitoredWindows.append(monitoredWindow)
                    }
                }

                state.activeSessions[bundleIdentifier] = active
                guard !monitoredWindows.isEmpty else {
                    state.activeSessions[bundleIdentifier]?.isCaptureInFlight = false
                    return .none
                }

                return capture(monitoredWindows, in: active.session, bundleIdentifier: bundleIdentifier)

            case let .windowsFailed(bundleIdentifier, message):
                state.activeSessions[bundleIdentifier]?.isCaptureInFlight = false
                let shouldLog = state.lastError != message
                state.recordDiagnostic(message)
                if shouldLog {
                    logger.log(.error, message, [:])
                }
                return .none

            case let .screenshotRecorded(record):
                logger.log(
                    .debug,
                    "Recorded screenshot",
                    ["path": .string(record.fileURL.path(percentEncoded: false))]
                )
                return .none

            case let .screenshotFailed(_, message):
                let shouldLog = state.lastError != message
                state.recordDiagnostic(message)
                if shouldLog {
                    logger.log(.error, message, [:])
                }
                return .none

            case let .captureCycleFinished(bundleIdentifier):
                state.activeSessions[bundleIdentifier]?.isCaptureInFlight = false
                return .none

            case .sessionClosed:
                return .none
            }
        }
    }

    private func attemptStart(
        _ application: RunningApplication,
        state: inout State
    ) -> Effect<Action> {
        guard let config = state.whitelist[application.bundleIdentifier], config.isEnabled else {
            return .none
        }
        guard state.activeSessions[application.bundleIdentifier] == nil else {
            return .none
        }

        let permission = permission
        guard state.permissionStatus == .authorized else {
            return .run { send in
                await send(.permissionResolved(await permission.request(), application))
            }
        }

        let session = CaptureSession(
            id: ids.uuid(),
            bundleIdentifier: config.bundleIdentifier,
            displayName: config.displayName,
            processIdentifier: application.processIdentifier,
            startedAt: date.now()
        )

        let persistence = persistence
        return .run { send in
            do {
                try await persistence.openSession(session)
                await send(.sessionOpened(session, application))
            } catch {
                await send(.sessionOpenFailed(error.localizedDescription))
            }
        }
    }

    private func closeSession(
        _ active: State.ActiveSession,
        endedAt: Date
    ) -> Effect<Action> {
        let persistence = persistence

        return .merge(
            .cancel(id: captureLoopID(active.config.bundleIdentifier)),
            .cancel(id: captureCycleID(active.session.id)),
            .run { send in
                do {
                    try await persistence.closeSession(active.session.id, endedAt)
                    await send(.sessionClosed(active.config.bundleIdentifier))
                } catch {
                    await send(.sessionOpenFailed(error.localizedDescription))
                }
            }
        )
    }

    private func captureLoop(
        bundleIdentifier: String,
        interval: Duration
    ) -> Effect<Action> {
        let clock = clock

        return .run { send in
            do {
                while !Task.isCancelled {
                    await send(.captureTick(bundleIdentifier))
                    try await clock.sleep(for: interval)
                }
            } catch {}
        }
        .cancellable(
            id: captureLoopID(bundleIdentifier),
            cancelInFlight: true
        )
    }

    private func capture(
        _ windows: [MonitoredWindow],
        in session: CaptureSession,
        bundleIdentifier: String
    ) -> Effect<Action> {
        let date = date
        let encoder = encoder
        let ids = ids
        let persistence = persistence
        let preferences = preferences
        let screenCapture = screenCapture
        let storage = storage

        return .run { send in
            for window in windows {
                do {
                    try await persistence.upsertWindow(window)

                    let options = preferences.encodingOptions()
                    let capturedAt = date.now()
                    let image = try await screenCapture.capture(window.systemWindowID)
                    let data = try await encoder.encode(image, options)
                    let url = try storage.screenshotURL(session, window, capturedAt, options.format)
                    let fileSize = try await storage.write(data, url)
                    let record = ScreenshotRecord(
                        id: ids.uuid(),
                        windowID: window.id,
                        sessionID: session.id,
                        capturedAt: capturedAt,
                        fileURL: url,
                        fileSizeBytes: fileSize
                    )
                    try await persistence.recordScreenshot(record)
                    await send(.screenshotRecorded(record))
                } catch {
                    await send(.screenshotFailed(bundleIdentifier, error.localizedDescription))
                }
            }
            await send(.captureCycleFinished(bundleIdentifier))
        }
        .cancellable(id: captureCycleID(session.id), cancelInFlight: true)
    }

    private func captureLoopID(_ bundleIdentifier: String) -> String {
        "capture-loop-\(bundleIdentifier)"
    }

    private func captureCycleID(_ sessionID: UUID) -> String {
        "capture-cycle-\(sessionID.uuidString)"
    }
}

extension CaptureEngineFeature.State {
    mutating func recordDiagnostic(_ message: String) {
        lastError = message
        if recentDiagnostics.last != message {
            recentDiagnostics.append(message)
        }
        if recentDiagnostics.count > 6 {
            recentDiagnostics.removeFirst(recentDiagnostics.count - 6)
        }
    }
}
