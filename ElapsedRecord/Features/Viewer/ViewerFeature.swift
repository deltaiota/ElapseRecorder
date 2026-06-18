import ComposableArchitecture
import Foundation

struct ViewerFeature: Reducer {
    struct State: Equatable {
        var apps: [AppCaptureSummary] = []
        var sessions: [CaptureSessionSummary] = []
        var windows: [WindowCaptureSummary] = []
        var windowScreenshots: [ScreenshotRecord] = []
        var flatScreenshots: [ScreenshotRecord] = []
        var selectedBundleIdentifier: String?
        var selectedSessionID: UUID?
        var selectedWindowID: UUID?
        var isShowingFlatGallery = false
        var isLoading = false
        var errorMessage: String?
    }

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
        case loadingFailed(String)
    }

    @Dependency(\.persistenceClient) private var persistence

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                state.isLoading = true
                return loadApps()

            case let .appsLoaded(apps):
                state.apps = apps
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
                state.isShowingFlatGallery = false

                guard let bundleIdentifier else { return .none }
                state.isLoading = true
                return loadSessions(bundleIdentifier: bundleIdentifier)

            case let .sessionsLoaded(sessions):
                state.sessions = sessions
                state.isLoading = false
                return .none

            case let .sessionSelected(sessionID):
                state.selectedSessionID = sessionID
                state.selectedWindowID = nil
                state.windows = []
                state.windowScreenshots = []
                state.isShowingFlatGallery = false

                guard let sessionID else { return .none }
                state.isLoading = true
                return loadWindows(sessionID: sessionID)

            case let .windowsLoaded(windows):
                state.windows = windows
                state.isLoading = false
                return .none

            case let .windowSelected(windowID):
                state.selectedWindowID = windowID
                state.windowScreenshots = []
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
                state.isShowingFlatGallery = true
                state.flatScreenshots = []
                state.isLoading = true
                return loadFlatScreenshots(bundleIdentifier: bundleIdentifier)

            case let .flatScreenshotsLoaded(records):
                state.flatScreenshots = records
                state.isLoading = false
                return .none

            case let .loadingFailed(message):
                state.errorMessage = message
                state.isLoading = false
                return .none
            }
        }
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
