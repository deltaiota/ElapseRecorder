import ComposableArchitecture
import Foundation

extension ViewerFeature {
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
}
