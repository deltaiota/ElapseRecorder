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
        case screenshotSelectionChanged(Set<UUID>)
        case quickLookURLChanged(URL?)
        case quickLookRequested(ScreenshotRecord)
        case refresh
        case revealScreenshotInFinder(ScreenshotRecord)
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
    @Dependency(\.capturePreferencesClient) private var preferences
    @Dependency(\.timelapseExportClient) private var timelapseExport
    @Dependency(\.exportPanelClient) private var exportPanel
    @Dependency(\.videoFrameExtractorClient) private var videoFrameExtractor
    @Dependency(\.date) private var date

    private nonisolated enum CancelID: Hashable { case export }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                state.isLoading = true
                return .merge(loadApps(), .send(.enforceRetentionRequested))

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

            case let .quickLookRequested(record):
                switch record.frameSource {
                case let .file(url):
                    state.quickLookURL = url
                    state.selectedScreenshotIDs = [record.id]
                    return .none
                case let .videoFrame(video, index):
                    // Quick Look needs a real file, so extract the compacted frame to a temp file.
                    state.selectedScreenshotIDs = [record.id]
                    let extractor = videoFrameExtractor
                    return .run { send in
                        guard let url = try? await extractor.temporaryImageFile(video, index) else { return }
                        await send(.quickLookURLChanged(url))
                    }
                }

            case let .revealScreenshotInFinder(record):
                let fileReveal = fileReveal
                return .run { _ in
                    await fileReveal.reveal(record.fileURL)
                }

            case let .exportTimelapseRequested(frames):
                guard !frames.isEmpty, !state.isExporting else { return .none }
                state.isExporting = true
                state.exportStatus = nil

                let exporter = timelapseExport
                let panel = exportPanel
                let fileReveal = fileReveal
                let suggestedName = state.exportSuggestedFileName
                let frameHashes = frames.map(\.perceptualHash)

                return .run { send in
                    guard let selection = await panel.present(suggestedName, frameHashes) else {
                        await send(.exportCancelled)
                        return
                    }

                    // Apply the chosen trim range and optional near-duplicate filter to the
                    // frame set before encoding, mirroring what the accessory previewed.
                    let selectedFrames = applyExportSelection(selection.options, to: frames)
                    guard !selectedFrames.isEmpty else {
                        await send(.exportCancelled)
                        return
                    }

                    do {
                        let request = TimelapseExportRequest(
                            frames: selectedFrames,
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
                guard policy.hasAnyLimit, !state.isEnforcingRetention else { return .none }
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
                // Remove the exact stored files first (root-agnostic, so it still works if the
                // capture location changed since these frames were written), then clean up the
                // now-empty session directory under the current root and delete the record.
                let paths = try await persistence.screenshotPathsForSession(session.id)
                _ = try? await fileStorage.removeFiles(paths.map { URL(filePath: $0) })
                try? await fileStorage.deleteSessionCaptures(session.bundleIdentifier, session.id)
                try await persistence.deleteSession(session.id)
                await send(.sessionDeleted(session.id))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func runIntegritySweep() -> Effect<Action> {
        let fileStorage = fileStorage
        let persistence = persistence
        return .run { send in
            do {
                let index = try await persistence.screenshotFileIndex()
                let recordedPaths = Set(index.map(\.path))

                // Orphan files: files under our capture root(s) that no record references.
                let files = try await fileStorage.captureFileURLs()
                let orphanFiles = files.filter { !recordedPaths.contains($0.path(percentEncoded: false)) }

                // Missing records: records whose file no longer exists (checked by absolute path).
                let existing = await fileStorage.filterExistingPaths(index.map(\.path))
                let missingIDs = index.filter { !existing.contains($0.path) }.map(\.id)

                try await persistence.deleteScreenshots(missingIDs)
                let reclaimed = try await fileStorage.removeFiles(orphanFiles)

                await send(.integritySweepFinished(StorageIntegrityResult(
                    removedRecordCount: missingIDs.count,
                    removedFileCount: orphanFiles.count,
                    reclaimedBytes: reclaimed
                )))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func enforceRetention(_ policy: RetentionPolicy) -> Effect<Action> {
        let fileStorage = fileStorage
        let persistence = persistence
        let now = date.now
        return .run { send in
            do {
                let sessions = try await persistence.endedSessionsOldestFirst()
                let ids = policy.sessionIDsToPrune(endedSessionsOldestFirst: sessions, now: now)
                let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

                for id in ids {
                    guard let session = byID[id] else { continue }
                    let paths = try await persistence.screenshotPathsForSession(id)
                    _ = try? await fileStorage.removeFiles(paths.map { URL(filePath: $0) })
                    try? await fileStorage.deleteSessionCaptures(session.bundleIdentifier, id)
                    try await persistence.deleteSession(id)
                }
                await send(.retentionEnforced(deletedSessionCount: ids.count))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    private func bulkDelete(before cutoff: Date, bundleIdentifier: String?) -> Effect<Action> {
        let fileStorage = fileStorage
        let persistence = persistence
        return .run { send in
            do {
                let sessions = try await persistence.sessionsStartedBefore(cutoff, bundleIdentifier)
                for session in sessions {
                    let paths = try await persistence.screenshotPathsForSession(session.id)
                    _ = try? await fileStorage.removeFiles(paths.map { URL(filePath: $0) })
                    try? await fileStorage.deleteSessionCaptures(session.bundleIdentifier, session.id)
                    try await persistence.deleteSession(session.id)
                }
                await send(.bulkDeleteFinished(deletedSessionCount: sessions.count))
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

/// Applies an export's trim range and optional near-duplicate filter to the ordered frames.
/// Pure and file-scoped so the export effect's `@Sendable` closure can call it directly.
private nonisolated func applyExportSelection(_ options: ExportOptions, to frames: [ExportFrame]) -> [ExportFrame] {
    var result = frames

    if let range = options.trimRange {
        let lower = max(0, range.lowerBound)
        let upper = min(frames.count - 1, range.upperBound)
        result = lower <= upper ? Array(frames[lower ... upper]) : []
    }

    if options.skipSimilarFrames {
        let keep = ExportFrameFilter.keptIndices(hashes: result.map(\.perceptualHash))
        result = keep.map { result[$0] }
    }

    return result
}
