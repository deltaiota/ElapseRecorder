import ComposableArchitecture
import Foundation

struct ViewerFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var apps: [AppCaptureSummary] = []
        var sessions: [CaptureSessionSummary] = []
        var windows: [WindowCaptureSummary] = []
        var windowScreenshots: [ScreenshotRecord] = []
        var flatScreenshots: [ScreenshotRecord] = []
        var selectedBundleIdentifier: String?
        var selectedSessionID: UUID?
        var selectedWindowID: UUID?
        var selectedScreenshot: ScreenshotRecord?
        var isShowingFlatGallery = false
        var isLoading = false
        var errorMessage: String?
    }

    @CasePathable
    enum Action: Equatable {
        case task
        case appsLoaded([AppCaptureSummary])
        case appSelected(String?)
        case sessionsLoaded([CaptureSessionSummary])
        case sessionSelected(UUID?)
        case windowsLoaded([WindowCaptureSummary])
        case windowSelected(UUID?)
        case windowScreenshotsLoaded([ScreenshotRecord])
        case flatGallerySelected
        case flatScreenshotsLoaded([ScreenshotRecord])
        case screenshotSelected(ScreenshotRecord?)
        case refresh
        case revealSelectedScreenshotInFinderButtonTapped
        case deleteSelectedSessionButtonTapped
        case sessionDeleted(UUID)
        case loadingFailed(String)
    }

    @Dependency(\.fileRevealClient) private var fileReveal
    @Dependency(\.fileStorageClient) private var fileStorage
    @Dependency(\.persistenceClient) private var persistence

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                state.isLoading = true
                return loadApps()

            case .refresh:
                return refresh(state)

            case let .appsLoaded(apps):
                state.apps = apps
                if let selectedBundleIdentifier = state.selectedBundleIdentifier,
                   !apps.contains(where: { $0.bundleIdentifier == selectedBundleIdentifier })
                {
                    state.clearSelection()
                }
                state.isLoading = false
                return .none

            case let .appSelected(bundleIdentifier):
                state.selectedBundleIdentifier = bundleIdentifier
                state.selectedSessionID = nil
                state.selectedWindowID = nil
                state.sessions = []
                state.windows = []
                state.windowScreenshots = []
                state.flatScreenshots = []
                state.selectedScreenshot = nil
                state.isShowingFlatGallery = false

                guard let bundleIdentifier else { return .none }
                state.isLoading = true
                return loadSessions(bundleIdentifier: bundleIdentifier)

            case let .sessionsLoaded(sessions):
                state.sessions = sessions
                if let selectedSessionID = state.selectedSessionID,
                   !sessions.contains(where: { $0.id == selectedSessionID })
                {
                    state.selectedSessionID = nil
                    state.selectedWindowID = nil
                    state.selectedScreenshot = nil
                    state.windows = []
                    state.windowScreenshots = []
                }
                state.isLoading = false
                return .none

            case let .sessionSelected(sessionID):
                state.selectedSessionID = sessionID
                state.selectedWindowID = nil
                state.windows = []
                state.windowScreenshots = []
                state.selectedScreenshot = nil
                state.isShowingFlatGallery = false

                guard let sessionID else { return .none }
                state.isLoading = true
                return loadWindows(sessionID: sessionID)

            case let .windowsLoaded(windows):
                state.windows = windows
                if let selectedWindowID = state.selectedWindowID,
                   !windows.contains(where: { $0.id == selectedWindowID })
                {
                    state.selectedWindowID = nil
                    state.selectedScreenshot = nil
                    state.windowScreenshots = []
                }
                state.isLoading = false
                return .none

            case let .windowSelected(windowID):
                state.selectedWindowID = windowID
                state.windowScreenshots = []
                state.selectedScreenshot = nil
                state.isShowingFlatGallery = false

                guard let windowID else { return .none }
                state.isLoading = true
                return loadWindowScreenshots(windowID: windowID)

            case let .windowScreenshotsLoaded(records):
                state.windowScreenshots = records
                state.isLoading = false
                return .none

            case .flatGallerySelected:
                guard let bundleIdentifier = state.selectedBundleIdentifier else { return .none }
                state.selectedSessionID = nil
                state.selectedWindowID = nil
                state.selectedScreenshot = nil
                state.isShowingFlatGallery = true
                state.flatScreenshots = []
                state.isLoading = true
                return loadFlatScreenshots(bundleIdentifier: bundleIdentifier)

            case let .flatScreenshotsLoaded(records):
                state.flatScreenshots = records
                state.isLoading = false
                return .none

            case let .screenshotSelected(record):
                state.selectedScreenshot = record
                return .none

            case .revealSelectedScreenshotInFinderButtonTapped:
                guard let url = state.selectedScreenshot?.fileURL else { return .none }
                let fileReveal = fileReveal
                return .run { _ in
                    await fileReveal.reveal(url)
                }

            case .deleteSelectedSessionButtonTapped:
                guard let session = state.selectedSession else { return .none }
                guard session.endedAt != nil else {
                    state.errorMessage = "Stop capture before deleting an active session."
                    return .none
                }

                state.isLoading = true
                let fileStorage = fileStorage
                let persistence = persistence
                return .run { send in
                    do {
                        try await fileStorage.deleteSessionCaptures(session.bundleIdentifier, session.id)
                        try await persistence.deleteSession(session.id)
                        await send(.sessionDeleted(session.id))
                    } catch {
                        await send(.loadingFailed(error.localizedDescription))
                    }
                }

            case let .sessionDeleted(sessionID):
                if state.selectedSessionID == sessionID {
                    state.selectedSessionID = nil
                    state.selectedWindowID = nil
                    state.selectedScreenshot = nil
                    state.windows = []
                    state.windowScreenshots = []
                }
                state.isLoading = false
                return .send(.refresh)

            case let .loadingFailed(message):
                state.errorMessage = message
                state.isLoading = false
                return .none
            }
        }
    }

    private func refresh(_ state: State) -> Effect<Action> {
        var effects: [Effect<Action>] = [loadApps()]

        if let bundleIdentifier = state.selectedBundleIdentifier {
            effects.append(loadSessions(bundleIdentifier: bundleIdentifier))

            if state.isShowingFlatGallery {
                effects.append(loadFlatScreenshots(bundleIdentifier: bundleIdentifier))
            }
        }

        if let sessionID = state.selectedSessionID {
            effects.append(loadWindows(sessionID: sessionID))
        }

        if let windowID = state.selectedWindowID {
            effects.append(loadWindowScreenshots(windowID: windowID))
        }

        return .merge(effects)
    }

    private func loadApps() -> Effect<Action> {
        .run { send in
            do {
                let apps = try await persistence.apps()
                await send(.appsLoaded(apps))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func loadSessions(bundleIdentifier: String) -> Effect<Action> {
        .run { send in
            do {
                let sessions = try await persistence.sessions(bundleIdentifier)
                await send(.sessionsLoaded(sessions))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func loadWindows(sessionID: UUID) -> Effect<Action> {
        .run { send in
            do {
                let windows = try await persistence.windows(sessionID)
                await send(.windowsLoaded(windows))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func loadWindowScreenshots(windowID: UUID) -> Effect<Action> {
        .run { send in
            do {
                let records = try await persistence.screenshotsForWindow(windowID)
                await send(.windowScreenshotsLoaded(records))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func loadFlatScreenshots(bundleIdentifier: String) -> Effect<Action> {
        .run { send in
            do {
                let records = try await persistence.screenshotsForApp(bundleIdentifier)
                await send(.flatScreenshotsLoaded(records))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }
}

extension ViewerFeature.State {
    var selectedSession: CaptureSessionSummary? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    mutating func clearSelection() {
        selectedBundleIdentifier = nil
        selectedSessionID = nil
        selectedWindowID = nil
        selectedScreenshot = nil
        isShowingFlatGallery = false
        sessions = []
        windows = []
        windowScreenshots = []
        flatScreenshots = []
    }
}
