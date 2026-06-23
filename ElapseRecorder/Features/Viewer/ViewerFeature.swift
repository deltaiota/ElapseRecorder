import ComposableArchitecture
import Foundation

struct ViewerFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var apps: [AppCaptureSummary] = []
        var sessions: [CaptureSessionSummary] = []
        var windows: [WindowCaptureSummary] = []
        var windowTimelineEntries: [CaptureTimelineEntry] = []
        var flatTimelineEntries: [CaptureTimelineEntry] = []
        var selectedBundleIdentifier: String?
        var selectedSessionID: UUID?
        var selectedWindowID: UUID?
        var selectedScreenshotIDs: Set<UUID> = []
        var quickLookURL: URL?
        var isShowingFlatGallery = false
        var isLoading = false
        var errorMessage: String?

        enum SessionListSelection: Hashable {
            case flat
            case session(id: UUID)
        }

        enum WindowPickerSelection: Hashable {
            case all
            case window(id: UUID)
        }

        var sessionListSelection: SessionListSelection? {
            get {
                if isShowingFlatGallery {
                    return .flat
                }

                guard let selectedSessionID else { return nil }
                return .session(id: selectedSessionID)
            }
            set {
                switch newValue {
                case .flat:
                    selectedSessionID = nil
                    isShowingFlatGallery = true
                case let .session(id):
                    selectedSessionID = id
                    isShowingFlatGallery = false
                case nil:
                    selectedSessionID = nil
                    isShowingFlatGallery = false
                }
            }
        }

        var windowPickerSelection: WindowPickerSelection {
            get {
                guard let selectedWindowID else { return .all }
                return .window(id: selectedWindowID)
            }
            set {
                switch newValue {
                case .all:
                    selectedWindowID = nil
                case let .window(id):
                    selectedWindowID = id
                }
            }
        }
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
        case windowPickerSelectionChanged(State.WindowPickerSelection)
        case timelineEntriesLoaded([CaptureTimelineEntry])
        case sessionListSelectionChanged(State.SessionListSelection?)
        case flatGallerySelected
        case flatTimelineEntriesLoaded([CaptureTimelineEntry])
        case screenshotSelectionChanged(Set<UUID>)
        case quickLookURLChanged(URL?)
        case refresh
        case revealScreenshotInFinder(ScreenshotRecord)
        case deleteSessionButtonTapped(CaptureSessionSummary)
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
                state.windowTimelineEntries = []
                state.flatTimelineEntries = []
                state.clearScreenshotSelection()
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
                    state.clearScreenshotSelection()
                    state.windows = []
                    state.windowTimelineEntries = []
                }
                state.isLoading = false
                return .none

            case let .sessionSelected(sessionID):
                return selectSession(sessionID, state: &state)

            case let .windowsLoaded(windows):
                state.windows = windows
                if let selectedWindowID = state.selectedWindowID,
                   !windows.contains(where: { $0.id == selectedWindowID })
                {
                    state.selectedWindowID = nil
                    state.clearScreenshotSelection()
                    state.windowTimelineEntries = []
                }
                state.isLoading = false
                return .none

            case let .windowSelected(windowID):
                guard windowID != state.selectedWindowID else { return .none }

                if let windowID {
                    return selectWindow(windowID, state: &state)
                }
                return selectAllWindows(state: &state)

            case let .windowPickerSelectionChanged(selection):
                guard selection != state.windowPickerSelection else { return .none }

                switch selection {
                case .all:
                    return selectAllWindows(state: &state)
                case let .window(id):
                    return selectWindow(id, state: &state)
                }

            case let .timelineEntriesLoaded(entries):
                state.windowTimelineEntries = entries
                state.isLoading = false
                return .none

            case let .sessionListSelectionChanged(selection):
                switch selection {
                case .flat:
                    return selectFlatGallery(state: &state)
                case let .session(id: sessionID):
                    return selectSession(sessionID, state: &state)
                case nil:
                    state.selectedSessionID = nil
                    state.selectedWindowID = nil
                    state.clearScreenshotSelection()
                    state.isShowingFlatGallery = false
                    state.windows = []
                    state.windowTimelineEntries = []
                    state.flatTimelineEntries = []
                    return .none
                }

            case .flatGallerySelected:
                return selectFlatGallery(state: &state)

            case let .flatTimelineEntriesLoaded(entries):
                state.flatTimelineEntries = entries
                state.isLoading = false
                return .none

            case let .screenshotSelectionChanged(ids):
                state.selectedScreenshotIDs = ids
                return .none

            case let .quickLookURLChanged(url):
                state.quickLookURL = url
                // Selection is the source of truth: when Quick Look navigates with the
                // arrow keys it reports the new item here, so move the grid selection to
                // match it.
                if let url, let id = state.screenshotID(forFileURL: url) {
                    state.selectedScreenshotIDs = [id]
                }
                return .none

            case let .revealScreenshotInFinder(record):
                let fileReveal = fileReveal
                return .run { _ in
                    await fileReveal.reveal(record.fileURL)
                }

            case let .deleteSessionButtonTapped(session):
                return deleteSession(session, state: &state)

            case .deleteSelectedSessionButtonTapped:
                guard let session = state.selectedSession else { return .none }
                return deleteSession(session, state: &state)

            case let .sessionDeleted(sessionID):
                if state.selectedSessionID == sessionID {
                    state.selectedSessionID = nil
                    state.selectedWindowID = nil
                    state.clearScreenshotSelection()
                    state.windows = []
                    state.windowTimelineEntries = []
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
                effects.append(loadFlatTimeline(bundleIdentifier: bundleIdentifier))
            }
        }

        if let sessionID = state.selectedSessionID {
            effects.append(loadWindows(sessionID: sessionID))

            if state.selectedWindowID == nil {
                effects.append(loadSessionTimeline(sessionID: sessionID))
            }
        }

        if let windowID = state.selectedWindowID {
            if let sessionID = state.selectedSessionID {
                effects.append(loadWindowTimeline(sessionID: sessionID, windowID: windowID))
            }
        }

        return .merge(effects)
    }

    private func selectSession(
        _ sessionID: UUID?,
        state: inout State
    ) -> Effect<Action> {
        state.selectedSessionID = sessionID
        state.selectedWindowID = nil
        state.windows = []
        state.windowTimelineEntries = []
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = false

        guard let sessionID else { return .none }
        state.isLoading = true
        return .merge(
            loadWindows(sessionID: sessionID),
            loadSessionTimeline(sessionID: sessionID)
        )
    }

    private func selectFlatGallery(state: inout State) -> Effect<Action> {
        guard let bundleIdentifier = state.selectedBundleIdentifier else { return .none }
        state.selectedSessionID = nil
        state.selectedWindowID = nil
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = true
        state.flatTimelineEntries = []
        state.isLoading = true
        return loadFlatTimeline(bundleIdentifier: bundleIdentifier)
    }

    private func selectAllWindows(state: inout State) -> Effect<Action> {
        state.selectedWindowID = nil
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = false

        guard let sessionID = state.selectedSessionID else { return .none }
        state.windowTimelineEntries = []
        state.isLoading = true
        return loadSessionTimeline(sessionID: sessionID)
    }

    private func selectWindow(
        _ windowID: UUID,
        state: inout State
    ) -> Effect<Action> {
        state.selectedWindowID = windowID
        state.windowTimelineEntries = []
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = false
        state.isLoading = true
        guard let sessionID = state.selectedSessionID else { return .none }
        return loadWindowTimeline(sessionID: sessionID, windowID: windowID)
    }

    private func deleteSession(
        _ session: CaptureSessionSummary,
        state: inout State
    ) -> Effect<Action> {
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

    private func loadSessionTimeline(sessionID: UUID) -> Effect<Action> {
        .run { send in
            do {
                let entries = try await persistence.timelineForSession(sessionID)
                await send(.timelineEntriesLoaded(entries))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func loadWindowTimeline(sessionID: UUID, windowID: UUID) -> Effect<Action> {
        .run { send in
            do {
                let entries = try await persistence.timelineForWindow(sessionID, windowID)
                await send(.timelineEntriesLoaded(entries))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func loadFlatTimeline(bundleIdentifier: String) -> Effect<Action> {
        .run { send in
            do {
                let entries = try await persistence.timelineForApp(bundleIdentifier)
                await send(.flatTimelineEntriesLoaded(entries))
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
        clearScreenshotSelection()
        isShowingFlatGallery = false
        sessions = []
        windows = []
        windowTimelineEntries = []
        flatTimelineEntries = []
    }

    mutating func clearScreenshotSelection() {
        selectedScreenshotIDs = []
        quickLookURL = nil
    }

    func screenshotID(forFileURL url: URL) -> UUID? {
        let entries = isShowingFlatGallery ? flatTimelineEntries : windowTimelineEntries
        for entry in entries {
            if case let .screenshot(record) = entry, record.fileURL == url {
                return record.id
            }
        }
        return nil
    }
}
