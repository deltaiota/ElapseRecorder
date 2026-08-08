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
        /// The complete frame scope currently represented by the bounded presentation page.
        var frameQuery: FrameQuery?
        var nextFrameCursor: FrameCursor?
        var frameTotalCount = 0
        var isLoadingMoreFrames = false
        /// Cadence is computed by streaming the complete scope, never from the visible page.
        var averageScreenshotInterval: TimeInterval?
        var cadenceSelection: FrameSelection?
        var selectedBundleIdentifier: String?
        var selectedSessionID: UUID?
        var selectedWindowID: UUID?
        var selectedSegment: WindowTitleSegment?
        var selectedScreenshotIDs: Set<UUID> = []
        var quickLookURL: URL?
        /// True from the moment an export is requested until it finishes/cancels — used to
        /// guard re-entry and disable the Export button (covers the destination-picker phase).
        var isExporting = false
        /// Non-nil only while frames are actually being encoded; drives the progress sheet.
        /// It stays nil during the AppKit save-panel phase so the two sheets never collide.
        var exportStatus: TimelapseExportStatus?
        /// True while a storage maintenance task (integrity sweep or bulk delete) is running.
        var isRunningStorageMaintenance = false
        /// The outcome of the most recent integrity sweep, shown in the storage management UI.
        var storageIntegrityResult: StorageIntegrityResult?
        /// True while the retention pruner is running, to guard against overlapping runs.
        var isEnforcingRetention = false
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
        case framePageLoaded(query: FrameQuery, page: FramePage, appending: Bool)
        case loadMoreFramesRequested
        case cadenceLoaded(selection: FrameSelection, average: TimeInterval?)
        case captureScreenshotRecorded(ScreenshotRecord, bundleIdentifier: String)
        case captureUnavailableRecorded(CaptureUnavailableRecord)
        case segmentCommitted(handle: RecordingSessionHandle, frameIDs: [UUID])
        case screenshotSelectionChanged(Set<UUID>)
        case quickLookURLChanged(URL?)
        case quickLookRequested(ScreenshotRecord)
        case refresh
        case revealScreenshotInFinder(ScreenshotRecord)
        case exportSelectionRequested(FrameSelection)
        /// Retained for direct callers with an already-bounded ad-hoc frame set.
        case exportTimelapseRequested(frames: [ExportFrame])
        case exportCancelButtonTapped
        case exportStarted(options: ExportOptions, totalFrames: Int)
        case exportProgressed(TimelapseExportProgress)
        case exportCompleted(URL)
        case exportFailed(String)
        case exportCancelled
        case deleteSessionButtonTapped(CaptureSessionSummary)
        case deleteSelectedSessionButtonTapped
        case sessionDeleted(UUID)
        case runIntegritySweepButtonTapped
        case integritySweepFinished(StorageIntegrityResult)
        case bulkDeleteRequested(before: Date, bundleIdentifier: String?)
        case bulkDeleteFinished(deletedSessionCount: Int)
        case enforceRetentionRequested
        case retentionEnforced(deletedSessionCount: Int)
        case loadingFailed(String)
    }

    @Dependency(\.fileRevealClient) private var fileReveal
    @Dependency(\.fileStorageClient) private var fileStorage
    @Dependency(\.persistenceClient) private var persistence
    @Dependency(\.storageCoordinatorClient) private var storageCoordinator
    @Dependency(\.maintenanceServiceClient) private var maintenance
    @Dependency(\.capturePreferencesClient) private var preferences
    @Dependency(\.timelapseExportClient) private var timelapseExport
    @Dependency(\.exportPanelClient) private var exportPanel
    @Dependency(\.videoFrameExtractorClient) private var videoFrameExtractor
    @Dependency(\.thumbnailClient) private var thumbnail
    @Dependency(\.perceptualHashClient) private var perceptualHash
    @Dependency(\.date) private var date

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
                state.clearFramePage()

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
                    state.clearFramePage()
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
                    state.clearFramePage()
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
                    state.clearFramePage()
                    return .none
                }

            case .flatGallerySelected:
                return selectFlatGallery(state: &state)

            case let .flatTimelineEntriesLoaded(entries):
                state.flatTimelineEntries = entries
                state.isLoading = false
                return .none

            case let .framePageLoaded(query, page, appending):
                guard state.frameQuery == query else { return .none }
                let entries = page.frames.map(CaptureTimelineEntry.screenshot)
                if state.isShowingFlatGallery {
                    if appending {
                        State.appendUnique(entries, to: &state.flatTimelineEntries)
                    } else {
                        state.flatTimelineEntries = entries
                    }
                } else {
                    if appending {
                        State.appendUnique(entries, to: &state.windowTimelineEntries)
                    } else {
                        state.windowTimelineEntries = entries
                    }
                }
                state.nextFrameCursor = page.nextCursor
                state.frameTotalCount = page.totalCount
                state.isLoadingMoreFrames = false
                state.isLoading = false
                return .none

            case .loadMoreFramesRequested:
                guard let query = state.frameQuery,
                      let cursor = state.nextFrameCursor,
                      !state.isLoadingMoreFrames
                else { return .none }
                state.isLoadingMoreFrames = true
                return loadFramePage(query: query, after: cursor, appending: true)

            case let .cadenceLoaded(selection, average):
                guard state.cadenceSelection == selection else { return .none }
                state.averageScreenshotInterval = average
                return .none

            case let .captureScreenshotRecorded(record, bundleIdentifier):
                let requiresStructuralRefresh = state.selectedBundleIdentifier == bundleIdentifier
                    && (!state.sessions.contains { $0.id == record.sessionID }
                        || (state.selectedSessionID == record.sessionID
                            && !state.windows.contains { $0.id == record.windowID }))
                state.recordCapturedScreenshot(record, bundleIdentifier: bundleIdentifier)
                return requiresStructuralRefresh ? .send(.refresh) : .none

            case let .captureUnavailableRecorded(record):
                state.recordCaptureUnavailable(record)
                return .none

            case let .segmentCommitted(handle, frameIDs):
                let affected = Set(frameIDs)
                let visibleEntries = state.isShowingFlatGallery
                    ? state.flatTimelineEntries
                    : state.windowTimelineEntries
                let hasAffectedVisibleFrame = visibleEntries.contains { entry in
                    guard case let .screenshot(record) = entry else { return false }
                    return affected.contains(record.id)
                }
                let queryMatches: Bool
                if let scope = state.frameQuery?.scope {
                    queryMatches = switch scope {
                    case let .app(bundleIdentifier): bundleIdentifier == handle.bundleIdentifier
                    case let .session(id): id == handle.sessionID
                    case let .window(sessionID, _): sessionID == handle.sessionID
                    }
                } else {
                    queryMatches = false
                }
                // Segment commit atomically repoints records and may delete old spool URLs.
                return hasAffectedVisibleFrame || queryMatches ? .send(.refresh) : .none

            case let .screenshotSelectionChanged(ids):
                state.selectedScreenshotIDs = ids
                let visible = state.isShowingFlatGallery
                    ? state.flatTimelineEntries
                    : state.windowTimelineEntries
                let orderedIDs = visible.compactMap { entry -> UUID? in
                    guard case let .screenshot(record) = entry, ids.contains(record.id) else { return nil }
                    return record.id
                }
                let selection = orderedIDs.count >= 2
                    ? FrameSelection.ids(orderedIDs)
                    : state.frameQuery.map(FrameSelection.query)
                state.cadenceSelection = selection
                state.averageScreenshotInterval = nil
                guard let selection else { return .none }
                return loadCadence(selection: selection)

            case let .quickLookURLChanged(url):
                state.quickLookURL = url
                // The `.quickLookPreview` modifier drives this binding for both opening and
                // arrow-key navigation, so keep the grid selection in sync with whatever
                // frame Quick Look is showing.
                if let url, let id = state.screenshotID(forFileURL: url) {
                    state.selectedScreenshotIDs = [id]
                }
                return .none

            case let .quickLookRequested(record):
                switch record.frameSource {
                case let .file(url):
                    state.quickLookURL = url
                    state.selectedScreenshotIDs = [record.id]
                    return .none
                case let .videoFrame(video, presentationTime):
                    // Quick Look needs a real file, so extract the exact persisted timestamp.
                    state.selectedScreenshotIDs = [record.id]
                    let extractor = videoFrameExtractor
                    return .run { send in
                        guard let url = try? await extractor.temporaryImageFileAtTime(video, presentationTime) else { return }
                        await send(.quickLookURLChanged(url))
                    }
                }

            case let .revealScreenshotInFinder(record):
                let fileReveal = fileReveal
                return .run { _ in
                    await fileReveal.reveal(record.fileURL)
                }

            case let .exportSelectionRequested(selection):
                guard !state.isExporting else { return .none }
                state.isExporting = true
                state.exportStatus = nil
                let loader = FramePageLoader(persistence: persistence)
                return exportEffect(suggestedName: state.exportSuggestedFileName) {
                    let snapshot = try await loader.snapshot(for: selection)
                    return ExportFrameStream(selection: snapshot.selection, count: snapshot.count) {
                        loader.exportFrames(for: snapshot.selection)
                    }
                }

            case let .exportTimelapseRequested(frames):
                guard !frames.isEmpty, !state.isExporting else { return .none }
                state.isExporting = true
                state.exportStatus = nil
                let source = ExportFrameStream(selection: .ids([]), count: frames.count) {
                    AsyncThrowingStream { continuation in
                        for frame in frames {
                            continuation.yield(frame)
                        }
                        continuation.finish()
                    }
                }
                return exportEffect(suggestedName: state.exportSuggestedFileName) { source }

            case .exportCancelButtonTapped:
                guard state.isExporting else { return .none }
                state.isExporting = false
                state.exportStatus = nil
                return .cancel(id: CancelID.export)

            case let .exportStarted(options, totalFrames):
                state.exportStatus = TimelapseExportStatus(
                    options: options,
                    totalFrames: totalFrames,
                    emittedFrames: 0,
                    startedAt: date.now
                )
                return .none

            case let .exportProgressed(progress):
                state.exportStatus?.emittedFrames = progress.emittedFrames
                return .none

            case .exportCompleted:
                state.isExporting = false
                state.exportStatus = nil
                return .none

            case let .exportFailed(message):
                state.isExporting = false
                state.exportStatus = nil
                state.errorMessage = message
                return .none

            case .exportCancelled:
                state.isExporting = false
                state.exportStatus = nil
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
                    state.clearFramePage()
                }
                state.isLoading = false
                return .send(.refresh)

            case .runIntegritySweepButtonTapped:
                guard !state.isRunningStorageMaintenance else { return .none }
                state.isRunningStorageMaintenance = true
                return runIntegritySweep()

            case let .integritySweepFinished(result):
                state.isRunningStorageMaintenance = false
                state.storageIntegrityResult = result
                return .send(.refresh)

            case let .bulkDeleteRequested(cutoff, bundleIdentifier):
                guard !state.isRunningStorageMaintenance else { return .none }
                state.isRunningStorageMaintenance = true
                return bulkDelete(before: cutoff, bundleIdentifier: bundleIdentifier)

            case .bulkDeleteFinished:
                state.isRunningStorageMaintenance = false
                return .send(.refresh)

            case .enforceRetentionRequested:
                let policy = preferences.retentionPolicy()
                guard policy.hasAnyLimit else { return .none }
                state.isEnforcingRetention = true
                return enforceRetention(policy)

            case let .retentionEnforced(deletedCount):
                state.isEnforcingRetention = false
                return deletedCount > 0 ? .send(.refresh) : .none

            case let .loadingFailed(message):
                state.errorMessage = message
                state.isLoading = false
                state.isRunningStorageMaintenance = false
                state.isEnforcingRetention = false
                return .none
            }
        }
    }

    private func exportEffect(
        suggestedName: String,
        source: @escaping @Sendable () async throws -> ExportFrameStream
    ) -> Effect<Action> {
        let exporter = timelapseExport
        let panel = exportPanel
        let fileReveal = fileReveal
        let thumbnail = thumbnail
        let perceptualHash = perceptualHash

        return .run { send in
            do {
                let rawSource = try await source()
                guard rawSource.count > 0 else {
                    await send(.exportCancelled)
                    return
                }
                let hashes = try await ExportFrameStreams.storedHashes(in: rawSource)
                guard let selection = await panel.present(suggestedName, hashes) else {
                    await send(.exportCancelled)
                    return
                }
                let selectedSource = try await ExportFrameStreams.filtered(
                    source: rawSource,
                    options: selection.options
                ) { frame in
                    let image = try await thumbnail.thumbnail(frame.frameSource, 64)
                    return perceptualHash.hash(CapturedImage(cgImage: image))
                }
                guard selectedSource.count > 0 else {
                    await send(.exportCancelled)
                    return
                }

                let request = TimelapseExportRequest(
                    source: selectedSource,
                    destinationURL: selection.destinationURL,
                    codec: selection.options.codec,
                    container: selection.options.container,
                    framesPerSecond: selection.options.framesPerSecond,
                    interpolationFrames: selection.options.interpolationFrames,
                    maxOutputDimension: selection.options.maxOutputDimension,
                    timestampOverlay: selection.options.timestampOverlay
                )
                await send(.exportStarted(options: selection.options, totalFrames: request.outputFrameCount))
                for try await progress in exporter.export(request) {
                    await send(.exportProgressed(progress))
                }
                try Task.checkCancellation()
                await send(.exportCompleted(selection.destinationURL))
                await fileReveal.reveal(selection.destinationURL)
            } catch is CancellationError {
                await send(.exportCancelled)
            } catch {
                await send(.exportFailed(error.localizedDescription))
            }
        }
        .cancellable(id: CancelID.export)
    }

    private func refresh(_ state: State) -> Effect<Action> {
        var effects: [Effect<Action>] = [loadApps()]

        if let bundleIdentifier = state.selectedBundleIdentifier {
            effects.append(loadSessions(bundleIdentifier: bundleIdentifier))

            if state.isShowingFlatGallery, let query = state.frameQuery {
                effects.append(loadFramePage(query: query, after: nil, appending: false))
                effects.append(loadCadence(selection: .query(query)))
            }
        }

        if let sessionID = state.selectedSessionID {
            effects.append(loadWindows(sessionID: sessionID))
            effects.append(loadTimelineGraph(sessionID: sessionID))

            if state.selectedWindowID != nil, let query = state.frameQuery {
                effects.append(loadFramePage(query: query, after: nil, appending: false))
                effects.append(loadCadence(selection: .query(query)))
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
        state.clearFramePage()

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
        return beginFrameQuery(.init(scope: .app(bundleIdentifier: bundleIdentifier)), state: &state)
    }

    /// Clearing the window selection returns to the session's timeline graph (already
    /// loaded on session select), so no screenshot grid is loaded here.
    private func selectAllWindows(state: inout State) -> Effect<Action> {
        state.selectedWindowID = nil
        state.selectedSegment = nil
        state.windowTimelineEntries = []
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = false
        state.clearFramePage()
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
        return beginFrameQuery(
            .init(scope: .window(sessionID: sessionID, windowID: windowID)),
            state: &state
        )
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
        return beginFrameQuery(
            .init(
                scope: .window(sessionID: sessionID, windowID: windowID),
                capturedAt: segment.startedAt ... segment.endedAt
            ),
            state: &state
        )
    }

    private func beginFrameQuery(_ query: FrameQuery, state: inout State) -> Effect<Action> {
        state.frameQuery = query
        state.nextFrameCursor = nil
        state.frameTotalCount = 0
        state.averageScreenshotInterval = nil
        state.cadenceSelection = .query(query)
        state.isLoadingMoreFrames = false
        return .merge(
            loadFramePage(query: query, after: nil, appending: false),
            loadCadence(selection: .query(query))
        )
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
        let maintenance = maintenance
        let environment = maintenanceEnvironment
        return .run { send in
            do {
                _ = try await maintenance.deleteSessions([session.id], environment)
                await send(.sessionDeleted(session.id))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func runIntegritySweep() -> Effect<Action> {
        let maintenance = maintenance
        let environment = maintenanceEnvironment
        return .run { send in
            do {
                try await send(.integritySweepFinished(await maintenance.integritySweep(environment)))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func enforceRetention(_ policy: RetentionPolicy) -> Effect<Action> {
        let maintenance = maintenance
        let environment = maintenanceEnvironment
        let now = date.now
        return .run { send in
            do {
                let count = try await maintenance.enforceRetention(policy, now, environment)
                await send(.retentionEnforced(deletedSessionCount: count))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func bulkDelete(before cutoff: Date, bundleIdentifier: String?) -> Effect<Action> {
        let maintenance = maintenance
        let environment = maintenanceEnvironment
        return .run { send in
            do {
                let count = try await maintenance.deleteBefore(cutoff, bundleIdentifier, environment)
                await send(.bulkDeleteFinished(deletedSessionCount: count))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private var maintenanceEnvironment: MaintenanceEnvironment {
        MaintenanceEnvironment(
            persistence: persistence,
            fileStorage: fileStorage,
            storageCoordinator: storageCoordinator
        )
    }

    private func loadFramePage(
        query: FrameQuery,
        after cursor: FrameCursor?,
        appending: Bool
    ) -> Effect<Action> {
        .run { send in
            do {
                let page = try await persistence.framePage(query, cursor, 240)
                await send(.framePageLoaded(query: query, page: page, appending: appending))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func loadCadence(selection: FrameSelection) -> Effect<Action> {
        let loader = FramePageLoader(persistence: persistence)
        return .run { send in
            do {
                let average = try await loader.averageInterval(for: selection)
                await send(.cadenceLoaded(selection: selection, average: average))
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
            let stamp = startedAt.formatted(
                .verbatim(
                    "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
                    timeZone: .current,
                    calendar: .current
                )
            )
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
        clearFramePage()
    }

    mutating func clearFramePage() {
        frameQuery = nil
        nextFrameCursor = nil
        frameTotalCount = 0
        isLoadingMoreFrames = false
        averageScreenshotInterval = nil
        cadenceSelection = nil
    }

    /// Applies one persisted capture without re-querying and copying the full library. This path
    /// runs once per frame, so it must stay proportional to the small summary/timeline surfaces
    /// being updated rather than to the total number of stored screenshots.
    mutating func recordCapturedScreenshot(
        _ record: ScreenshotRecord,
        bundleIdentifier: String
    ) {
        let visibleEntries = isShowingFlatGallery ? flatTimelineEntries : windowTimelineEntries
        let wasVisible = visibleEntries.contains { $0.id == record.id }
        let matchesCurrentQuery = frameQuery?.matches(record, bundleIdentifier: bundleIdentifier) == true
        if let index = apps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            let previousLastCapture = apps[index].lastCapturedAt
            apps[index].screenshotCount += 1
            apps[index].sizeBytes += record.fileSizeBytes
            apps[index].lastCapturedAt = max(previousLastCapture ?? record.capturedAt, record.capturedAt)

            if let session = sessions.first(where: { $0.id == record.sessionID }),
               session.endedAt == nil
            {
                let priorEnd = max(session.startedAt, previousLastCapture ?? session.startedAt)
                apps[index].totalActiveDuration += max(0, record.capturedAt.timeIntervalSince(priorEnd))
            }
        }

        if let index = sessions.firstIndex(where: { $0.id == record.sessionID }) {
            sessions[index].screenshotCount += 1
            sessions[index].sizeBytes += record.fileSizeBytes
        }
        if let index = windows.firstIndex(where: { $0.id == record.windowID }) {
            windows[index].screenshotCount += 1
        }

        if isShowingFlatGallery, selectedBundleIdentifier == bundleIdentifier {
            Self.appendIfNew(.screenshot(record), to: &flatTimelineEntries)
        }
        if selectedSessionID == record.sessionID,
           selectedWindowID == record.windowID,
           selectedSegment.map({ record.capturedAt >= $0.startedAt && record.capturedAt <= $0.endedAt }) ?? true
        {
            Self.appendIfNew(.screenshot(record), to: &windowTimelineEntries)
        }

        if var timeline = sessionTimeline,
           timeline.sessionID == record.sessionID,
           let laneIndex = timeline.lanes.firstIndex(where: { $0.windowID == record.windowID })
        {
            timeline.lanes[laneIndex].diedAt = max(timeline.lanes[laneIndex].diedAt, record.capturedAt)
            timeline.lanes[laneIndex].screenshotCount += 1
            if let segmentIndex = timeline.lanes[laneIndex].segments.lastIndex(where: {
                record.capturedAt >= $0.startedAt && record.capturedAt <= $0.endedAt
            }) {
                timeline.lanes[laneIndex].segments[segmentIndex].screenshotCount += 1
            }
            sessionTimeline = timeline
        }
        if matchesCurrentQuery, !wasVisible {
            frameTotalCount += 1
        }
    }

    mutating func recordCaptureUnavailable(_ record: CaptureUnavailableRecord) {
        guard selectedSessionID == record.sessionID else { return }

        let entry = CaptureTimelineEntry.unavailable(record)
        if selectedWindowID != nil {
            Self.upsert(entry, in: &windowTimelineEntries)
        }
        if var timeline = sessionTimeline, timeline.sessionID == record.sessionID {
            if let index = timeline.unavailableSpans.lastIndex(where: { $0.startedAt == record.startedAt }) {
                timeline.unavailableSpans[index].endedAt = record.endedAt
            } else {
                timeline.unavailableSpans.append(TimeSpan(startedAt: record.startedAt, endedAt: record.endedAt))
            }
            sessionTimeline = timeline
        }
    }

    private static func appendIfNew(
        _ entry: CaptureTimelineEntry,
        to entries: inout [CaptureTimelineEntry]
    ) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
    }

    static func appendUnique(
        _ newEntries: [CaptureTimelineEntry],
        to entries: inout [CaptureTimelineEntry]
    ) {
        var existingIDs = Set(entries.map(\.id))
        entries.append(contentsOf: newEntries.filter { existingIDs.insert($0.id).inserted })
    }

    private static func upsert(
        _ entry: CaptureTimelineEntry,
        in entries: inout [CaptureTimelineEntry]
    ) {
        if entries.last?.id == entry.id {
            entries[entries.count - 1] = entry
        } else if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
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
