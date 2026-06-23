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
        var lastWorkspaceEvent: WorkspaceEvent?
        var recentDiagnostics: [String] = []

        struct ActiveSession: Equatable {
            var application: RunningApplication
            var config: WhitelistedAppConfig
            var session: CaptureSession
            var nextWindowNumber: Int = 1
            var windowsBySystemID: [Int: MonitoredWindow] = [:]
            var isCaptureInFlight = false
            var captureUnavailableReason: CaptureUnavailableReason?
        }
    }

    enum Action: Equatable {
        case task
        case requestPermissionButtonTapped
        case refreshRunningApplications
        case captureStart(String)
        case captureStop(String)
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
                let date = date
                let logger = logger
                let permission = permission
                let persistence = persistence
                let workspace = workspace

                return .merge(
                    .run { send in
                        // Close sessions left open by a previous run BEFORE resolving
                        // permission or enumerating running apps, so the stale cleanup can
                        // never race with — and accidentally close — a freshly opened
                        // session for the current run.
                        do {
                            let closed = try await persistence.closeOpenSessions(date.now())
                            await send(.staleOpenSessionsClosed(closed))
                        } catch {
                            await send(.staleOpenSessionCloseFailed(error.localizedDescription))
                        }
                        logger.log(.info, "Capture engine started", [:])
                        await send(.permissionResolved(await permission.status(), nil))
                        await send(.refreshRunningApplications)
                    },
                    .run { send in
                        for await event in workspace.events() {
                            await send(.workspaceEvent(event))
                        }
                    }
                    .cancellable(id: workspaceEventsID, cancelInFlight: true)
                )

            case .requestPermissionButtonTapped:
                let permission = permission
                return .run { send in
                    await send(.permissionResolved(await permission.request(), nil))
                }

            case .refreshRunningApplications:
                let workspace = workspace
                return .run { send in
                    await send(.runningApplicationsLoaded(await workspace.runningApplications()))
                }

            case let .captureStart(bundleIdentifier):
                guard let config = state.whitelist[bundleIdentifier] else {
                    return .none
                }
                guard let application = state.runningApplications[bundleIdentifier] else {
                    state.recordDiagnostic("Cannot start capture because \(config.displayName) is not running.")
                    return .none
                }
                return startSession(application, config: config, state: &state)

            case let .captureStop(bundleIdentifier):
                guard let active = state.activeSessions.removeValue(forKey: bundleIdentifier) else {
                    return .none
                }
                return closeSession(active, endedAt: date.now())

            case let .staleOpenSessionsClosed(count):
                if count > 0 {
                    state.recordDiagnostic("Closed \(count) stale open capture sessions.")
                }
                return .none

            case let .staleOpenSessionCloseFailed(message):
                state.recordDiagnostic(message)
                logger.log(.error, message, [:])
                return .none

            case let .whitelistUpdated(configs):
                state.whitelist = Dictionary(
                    configs.map { ($0.bundleIdentifier, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )

                var effects: [Effect<Action>] = []
                for (bundleIdentifier, active) in state.activeSessions {
                    guard let updatedConfig = state.whitelist[bundleIdentifier] else {
                        state.activeSessions[bundleIdentifier] = nil
                        effects.append(closeSession(active, endedAt: date.now()))
                        continue
                    }

                    guard updatedConfig.allowsActiveSession else {
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
                    attemptAutoStart(application, state: &state)
                }

                return .merge(effects + startEffects)

            case let .runningApplicationsLoaded(applications):
                state.runningApplications = Dictionary(
                    applications.map { ($0.bundleIdentifier, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )
                return .merge(applications.map { attemptAutoStart($0, state: &state) })

            case let .runningApplicationRegistered(application):
                // Merge a single known-running app into the table without discarding the
                // others. Used by menu actions that need the app present before a manual
                // capture start; sending runningApplicationsLoaded([app]) there would wipe
                // every other running app from state.
                state.runningApplications[application.bundleIdentifier] = application
                return attemptAutoStart(application, state: &state)

            case let .workspaceEvent(.launched(application)):
                state.lastWorkspaceEvent = .launched(application)
                state.runningApplications[application.bundleIdentifier] = application
                return attemptAutoStart(application, state: &state)

            case let .workspaceEvent(.terminated(application)):
                state.lastWorkspaceEvent = .terminated(application)
                state.runningApplications[application.bundleIdentifier] = nil
                guard let active = state.activeSessions.removeValue(forKey: application.bundleIdentifier) else {
                    return .none
                }
                return closeSession(active, endedAt: date.now())

            case let .workspaceEvent(.activated(application)):
                state.lastWorkspaceEvent = .activated(application)
                state.runningApplications[application.bundleIdentifier] = application
                return .none

            case let .permissionResolved(status, application):
                state.permissionStatus = status
                if status == .authorized {
                    state.clearPermissionDeniedError()
                }

                guard status == .authorized else {
                    if status == .denied {
                        state.recordDiagnostic(CaptureEngineError.screenRecordingPermissionDenied.localizedDescription)
                    }
                    return .none
                }

                guard let application else {
                    return .merge(state.runningApplications.values.map { attemptAutoStart($0, state: &state) })
                }

                guard let config = state.whitelist[application.bundleIdentifier] else {
                    return .none
                }
                return startSession(application, config: config, state: &state)

            case let .sessionOpened(session, application):
                // The active session was already inserted synchronously when the start
                // was requested; persistence has now confirmed it, so the capture loop
                // can safely begin. If the slot is gone or holds a different session the
                // run was superseded (terminated/replaced) and this row is orphaned.
                guard let active = state.activeSessions[application.bundleIdentifier],
                      active.session.id == session.id
                else {
                    logger.log(
                        .info,
                        "Closing orphaned session",
                        ["bundle": .string(application.bundleIdentifier), "session": .string(session.id.uuidString)]
                    )
                    return closeAbandonedSession(session)
                }

                logger.log(
                    .info,
                    "Session capture started",
                    ["bundle": .string(application.bundleIdentifier), "session": .string(session.id.uuidString)]
                )
                return captureLoop(
                    bundleIdentifier: application.bundleIdentifier,
                    interval: active.config.sanitizedInterval
                )

            case let .sessionOpenFailed(bundleIdentifier, sessionID, message):
                if let bundleIdentifier,
                   let sessionID,
                   state.activeSessions[bundleIdentifier]?.session.id == sessionID
                {
                    state.activeSessions[bundleIdentifier] = nil
                }
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
                let capturableWindows = CapturableWindow.capturableWindows(from: windows)

                // `capturableWindows` applies `shouldCapture`, which drops minimized/hidden
                // windows (not on-screen) and Stage Manager-stowed windows (flagged by the
                // live layer). An empty result therefore means every window of this app is
                // currently unavailable. Mark a placeholder once on the transition into that
                // state, and only after the session has seen real windows so the timeline
                // doesn't open with a spurious placeholder.
                guard !capturableWindows.isEmpty else {
                    active.isCaptureInFlight = false

                    let hasSeenWindows = !active.windowsBySystemID.isEmpty
                    let wasAlreadyUnavailable = active.captureUnavailableReason != nil
                    if hasSeenWindows {
                        active.captureUnavailableReason = .windowMinimized
                    }
                    state.activeSessions[bundleIdentifier] = active

                    guard hasSeenWindows, !wasAlreadyUnavailable else { return .none }
                    return recordCaptureUnavailable(
                        in: active.session,
                        reason: .windowMinimized,
                        at: seenAt
                    )
                }

                active.captureUnavailableReason = nil

                for window in capturableWindows {
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
                for (bundleIdentifier, active) in state.activeSessions where active.session.id == record.sessionID {
                    state.activeSessions[bundleIdentifier]?.captureUnavailableReason = nil
                }
                logger.log(
                    .debug,
                    "Recorded screenshot",
                    ["path": .string(record.fileURL.path(percentEncoded: false))]
                )
                return .none

            case let .captureUnavailableRecorded(record):
                for (bundleIdentifier, active) in state.activeSessions where active.session.id == record.sessionID {
                    state.activeSessions[bundleIdentifier]?.captureUnavailableReason = record.reason
                }
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

    private func attemptAutoStart(
        _ application: RunningApplication,
        state: inout State
    ) -> Effect<Action> {
        guard let config = state.whitelist[application.bundleIdentifier],
              config.captureMode == .auto,
              config.isEnabled
        else {
            return .none
        }
        return startSession(application, config: config, state: &state)
    }

    /// The single, synchronous chokepoint for opening a capture session.
    ///
    /// Auto-launch detection, the user's manual capture button, and the post-permission
    /// retry all funnel through here. The `ActiveSession` is inserted into `state`
    /// synchronously, so the `activeSessions[bundleIdentifier] == nil` guard atomically
    /// claims the slot. Because the reducer processes actions serially, every other
    /// near-simultaneous trigger (running-app load, launch event, whitelist sweep,
    /// duplicate permission resolution) sees the claim and is ignored — there is no async
    /// gap in which two sessions can be opened for the same app.
    private func startSession(
        _ application: RunningApplication,
        config: WhitelistedAppConfig,
        state: inout State
    ) -> Effect<Action> {
        guard config.allowsSessionStart else { return .none }
        guard state.activeSessions[application.bundleIdentifier] == nil else { return .none }

        guard state.permissionStatus == .authorized else {
            let permission = permission
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
        state.activeSessions[application.bundleIdentifier] = State.ActiveSession(
            application: application,
            config: config,
            session: session
        )
        logger.log(
            .info,
            "Opening session",
            ["bundle": .string(application.bundleIdentifier), "session": .string(session.id.uuidString)]
        )

        let persistence = persistence
        return .run { send in
            do {
                try await persistence.openSession(session)
                await send(.sessionOpened(session, application))
            } catch {
                await send(.sessionOpenFailed(application.bundleIdentifier, session.id, error.localizedDescription))
            }
        }
    }

    private func closeSession(
        _ active: State.ActiveSession,
        endedAt: Date
    ) -> Effect<Action> {
        let logger = logger
        let persistence = persistence
        logger.log(
            .info,
            "Closing session",
            [
                "bundle": .string(active.config.bundleIdentifier),
                "session": .string(active.session.id.uuidString),
            ]
        )

        return .merge(
            .cancel(id: captureLoopID(active.config.bundleIdentifier)),
            .cancel(id: captureCycleID(active.session.id)),
            .run { send in
                do {
                    try await persistence.closeSession(active.session.id, endedAt)
                    await send(.sessionClosed(active.config.bundleIdentifier))
                } catch {
                    await send(.sessionOpenFailed(nil, nil, error.localizedDescription))
                }
            }
        )
    }

    private func closeAbandonedSession(_ session: CaptureSession) -> Effect<Action> {
        let date = date
        let persistence = persistence

        return .run { send in
            do {
                try await persistence.closeSession(session.id, date.now())
                await send(.sessionClosed(session.bundleIdentifier))
            } catch {
                await send(.sessionOpenFailed(nil, nil, error.localizedDescription))
            }
        }
    }

    private func captureLoop(
        bundleIdentifier: String,
        interval: Duration
    ) -> Effect<Action> {
        let clock = clock

        return .run { send in
            // Drift-free fixed-rate scheduling. Each cycle's real elapsed time (tick
            // dispatch and the sleep itself) is measured and accumulated, and the next
            // sleep is sized so the running total tracks the absolute grid n·interval.
            // Sleeping a flat `interval` after each tick instead lets per-cycle overhead
            // and any sleep overshoot accumulate, drifting the effective period longer
            // than requested; feeding the measured elapsed back keeps the long-run
            // average exactly at `interval`.
            do {
                var elapsed: Duration = .zero
                var tickCount = 0

                while !Task.isCancelled {
                    elapsed += await clock.measure {
                        await send(.captureTick(bundleIdentifier))
                    }
                    tickCount += 1

                    let remaining = interval * tickCount - elapsed
                    if remaining > .zero {
                        elapsed += try await clock.measure {
                            try await clock.sleep(for: remaining)
                        }
                    }
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

    private func recordCaptureUnavailable(
        in session: CaptureSession,
        reason: CaptureUnavailableReason,
        at date: Date
    ) -> Effect<Action> {
        let persistence = persistence
        let record = CaptureUnavailableRecord(
            id: ids.uuid(),
            sessionID: session.id,
            startedAt: date,
            endedAt: date,
            reason: reason
        )

        return .run { send in
            do {
                try await persistence.recordCaptureUnavailable(record)
                await send(.captureUnavailableRecorded(record))
            } catch {
                await send(.screenshotFailed(session.bundleIdentifier, error.localizedDescription))
            }
        }
    }

    private func captureLoopID(_ bundleIdentifier: String) -> String {
        "capture-loop-\(bundleIdentifier)"
    }

    private func captureCycleID(_ sessionID: UUID) -> String {
        "capture-cycle-\(sessionID.uuidString)"
    }

    private var workspaceEventsID: String {
        "workspace-events"
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

    mutating func clearPermissionDeniedError() {
        if lastError == CaptureEngineError.screenRecordingPermissionDenied.localizedDescription {
            lastError = nil
        }
    }
}

private extension WhitelistedAppConfig {
    var allowsSessionStart: Bool {
        captureMode == .manual || isEnabled
    }

    var allowsActiveSession: Bool {
        allowsSessionStart
    }
}
