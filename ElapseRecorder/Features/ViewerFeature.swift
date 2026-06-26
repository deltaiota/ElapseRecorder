import ComposableArchitecture
import Foundation

struct ViewerFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var apps: [AppCaptureSummary] = []
        var sessions: [CaptureSessionSummary] = []
        var windows: [WindowCaptureSummary] = []
        var sessionTimeline: SessionTimeline?
        var windowTimelineEntries: [CaptureTimelineEntry] = []
        var flatTimelineEntries: [CaptureTimelineEntry] = []
        var selectedBundleIdentifier: String?
        var selectedSessionID: UUID?
        var selectedWindowID: UUID?
        var selectedSegment: WindowTitleSegment?
        var selectedScreenshotIDs: Set<UUID> = []
        var quickLookURL: URL?
        var exportProgress: Double?
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

        /// A session is selected but no specific window/segment is — show the lifecycle
        /// timeline graph rather than a screenshot grid.
        var isShowingTimelineGraph: Bool {
            selectedSessionID != nil && selectedWindowID == nil && !isShowingFlatGallery
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
        case sessionTimelineLoaded(SessionTimeline)
        case windowSelected(UUID?)
        case windowSegmentSelected(windowID: UUID, segment: WindowTitleSegment)
        case windowPickerSelectionChanged(State.WindowPickerSelection)
        case timelineEntriesLoaded([CaptureTimelineEntry])
        case sessionListSelectionChanged(State.SessionListSelection?)
        case flatGallerySelected
        case flatTimelineEntriesLoaded([CaptureTimelineEntry])
        case screenshotSelectionChanged(Set<UUID>)
        case quickLookURLChanged(URL?)
        case refresh
        case revealScreenshotInFinder(ScreenshotRecord)
        case exportTimelapseRequested(urls: [URL])
        case exportProgressed(Double)
        case exportCompleted(URL)
        case exportFailed(String)
        case exportCancelled
        case deleteSessionButtonTapped(CaptureSessionSummary)
        case deleteSelectedSessionButtonTapped
        case sessionDeleted(UUID)
        case loadingFailed(String)
    }

    @Dependency(\.fileRevealClient) private var fileReveal
    @Dependency(\.fileStorageClient) private var fileStorage
    @Dependency(\.persistenceClient) private var persistence
    @Dependency(\.timelapseExportClient) private var timelapseExport
    @Dependency(\.exportPanelClient) private var exportPanel

    private nonisolated enum CancelID: Hashable { case export }

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
                state.selectedSegment = nil
                state.sessions = []
                state.windows = []
                state.sessionTimeline = nil
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
                    state.selectedSegment = nil
                    state.clearScreenshotSelection()
                    state.windows = []
                    state.sessionTimeline = nil
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
                    state.selectedSegment = nil
                    state.clearScreenshotSelection()
                    state.windowTimelineEntries = []
                }
                state.isLoading = false
                return .none

            case let .sessionTimelineLoaded(timeline):
                state.sessionTimeline = timeline
                state.isLoading = false
                return .none

            case let .windowSegmentSelected(windowID, segment):
                return selectWindowSegment(windowID: windowID, segment: segment, state: &state)

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
                    state.selectedSegment = nil
                    state.clearScreenshotSelection()
                    state.isShowingFlatGallery = false
                    state.windows = []
                    state.sessionTimeline = nil
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
                // The `.quickLookPreview` modifier drives this binding for both opening and
                // arrow-key navigation, so keep the grid selection in sync with whatever
                // frame Quick Look is showing.
                if let url, let id = state.screenshotID(forFileURL: url) {
                    state.selectedScreenshotIDs = [id]
                }
                return .none

            case let .revealScreenshotInFinder(record):
                let fileReveal = fileReveal
                return .run { _ in
                    await fileReveal.reveal(record.fileURL)
                }

            case let .exportTimelapseRequested(urls):
                guard !urls.isEmpty, state.exportProgress == nil else { return .none }
                state.exportProgress = 0

                let exporter = timelapseExport
                let panel = exportPanel
                let fileReveal = fileReveal
                let suggestedName = state.exportSuggestedFileName

                return .run { send in
                    guard let selection = await panel.present(suggestedName) else {
                        await send(.exportCancelled)
                        return
                    }

                    do {
                        let request = TimelapseExportRequest(
                            imageURLs: urls,
                            destinationURL: selection.destinationURL,
                            codec: selection.options.codec,
                            container: selection.options.container,
                            framesPerSecond: selection.options.framesPerSecond,
                            interpolationFrames: selection.options.interpolationFrames
                        )
                        for try await progress in exporter.export(request) {
                            await send(.exportProgressed(progress))
                        }
                        await send(.exportCompleted(selection.destinationURL))
                        await fileReveal.reveal(selection.destinationURL)
                    } catch is CancellationError {
                        await send(.exportCancelled)
                    } catch {
                        await send(.exportFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.export)

            case let .exportProgressed(progress):
                state.exportProgress = progress
                return .none

            case .exportCompleted:
                state.exportProgress = nil
                return .none

            case let .exportFailed(message):
                state.exportProgress = nil
                state.errorMessage = message
                return .none

            case .exportCancelled:
                state.exportProgress = nil
                return .none

            case let .deleteSessionButtonTapped(session):
                return deleteSession(session, state: &state)

            case .deleteSelectedSessionButtonTapped:
                guard let session = state.selectedSession else { return .none }
                return deleteSession(session, state: &state)

            case let .sessionDeleted(sessionID):
                if state.selectedSessionID == sessionID {
                    state.selectedSessionID = nil
                    state.selectedWindowID = nil
                    state.selectedSegment = nil
                    state.clearScreenshotSelection()
                    state.windows = []
                    state.sessionTimeline = nil
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
            effects.append(loadTimelineGraph(sessionID: sessionID))

            if let windowID = state.selectedWindowID {
                effects.append(
                    loadWindowTimeline(sessionID: sessionID, windowID: windowID, range: state.selectedSegment)
                )
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
        state.selectedSegment = nil
        state.windows = []
        state.sessionTimeline = nil
        state.windowTimelineEntries = []
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = false

        guard let sessionID else { return .none }
        state.isLoading = true
        return .merge(
            loadWindows(sessionID: sessionID),
            loadTimelineGraph(sessionID: sessionID)
        )
    }

    private func selectFlatGallery(state: inout State) -> Effect<Action> {
        guard let bundleIdentifier = state.selectedBundleIdentifier else { return .none }
        state.selectedSessionID = nil
        state.selectedWindowID = nil
        state.selectedSegment = nil
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = true
        state.sessionTimeline = nil
        state.flatTimelineEntries = []
        state.isLoading = true
        return loadFlatTimeline(bundleIdentifier: bundleIdentifier)
    }

    /// Clearing the window selection returns to the session's timeline graph (already
    /// loaded on session select), so no screenshot grid is loaded here.
    private func selectAllWindows(state: inout State) -> Effect<Action> {
        state.selectedWindowID = nil
        state.selectedSegment = nil
        state.windowTimelineEntries = []
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = false
        return .none
    }

    private func selectWindow(
        _ windowID: UUID,
        state: inout State
    ) -> Effect<Action> {
        state.selectedWindowID = windowID
        state.selectedSegment = nil
        state.windowTimelineEntries = []
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = false
        state.isLoading = true
        guard let sessionID = state.selectedSessionID else { return .none }
        return loadWindowTimeline(sessionID: sessionID, windowID: windowID, range: nil)
    }

    private func selectWindowSegment(
        windowID: UUID,
        segment: WindowTitleSegment,
        state: inout State
    ) -> Effect<Action> {
        state.selectedWindowID = windowID
        state.selectedSegment = segment
        state.windowTimelineEntries = []
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = false
        state.isLoading = true
        guard let sessionID = state.selectedSessionID else { return .none }
        return loadWindowTimeline(sessionID: sessionID, windowID: windowID, range: segment)
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

    private func loadTimelineGraph(sessionID: UUID) -> Effect<Action> {
        .run { send in
            do {
                let timeline = try await persistence.sessionTimeline(sessionID)
                await send(.sessionTimelineLoaded(timeline))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func loadWindowTimeline(sessionID: UUID, windowID: UUID, range: WindowTitleSegment?) -> Effect<Action> {
        .run { send in
            do {
                let entries = try await persistence.timelineForWindow(sessionID, windowID)
                // A selected title segment narrows the grid to that segment's time range.
                let filtered = range.map { segment in
                    entries.filter { $0.occurredAt >= segment.startedAt && $0.occurredAt <= segment.endedAt }
                } ?? entries
                await send(.timelineEntriesLoaded(filtered))
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

    /// A friendly default file name for an exported timelapse, based on the current app and
    /// session selection.
    var exportSuggestedFileName: String {
        let appName = selectedBundleIdentifier
            .flatMap { id in apps.first { $0.bundleIdentifier == id } }?
            .displayName ?? "Capture"

        if let startedAt = selectedSession?.startedAt {
            let stamp = startedAt.formatted(.dateTime.year().month().day().hour().minute())
            return "\(appName) Timelapse \(stamp)"
        }
        return "\(appName) Timelapse"
    }

    mutating func clearSelection() {
        selectedBundleIdentifier = nil
        selectedSessionID = nil
        selectedWindowID = nil
        selectedSegment = nil
        clearScreenshotSelection()
        isShowingFlatGallery = false
        sessions = []
        windows = []
        sessionTimeline = nil
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
