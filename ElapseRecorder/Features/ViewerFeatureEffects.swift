import ComposableArchitecture
import Foundation

extension ViewerFeature {
    func exportEffect(
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

    func refresh(_ state: State) -> Effect<Action> {
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

    func selectSession(
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

    func selectFlatGallery(state: inout State) -> Effect<Action> {
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
    func selectAllWindows(state: inout State) -> Effect<Action> {
        state.selectedWindowID = nil
        state.selectedSegment = nil
        state.windowTimelineEntries = []
        state.clearScreenshotSelection()
        state.isShowingFlatGallery = false
        state.clearFramePage()
        return .none
    }

    func selectWindow(
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

    func selectWindowSegment(
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

    func beginFrameQuery(_ query: FrameQuery, state: inout State) -> Effect<Action> {
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

    func deleteSession(
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

    func runIntegritySweep() -> Effect<Action> {
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

    func enforceRetention(_ policy: RetentionPolicy) -> Effect<Action> {
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

    func bulkDelete(before cutoff: Date, bundleIdentifier: String?) -> Effect<Action> {
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

    var maintenanceEnvironment: MaintenanceEnvironment {
        MaintenanceEnvironment(
            persistence: persistence,
            fileStorage: fileStorage,
            storageCoordinator: storageCoordinator
        )
    }

    func loadFramePage(
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

    func loadCadence(selection: FrameSelection) -> Effect<Action> {
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

    func loadApps() -> Effect<Action> {
        .run { send in
            do {
                let apps = try await persistence.apps()
                await send(.appsLoaded(apps))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    func loadSessions(bundleIdentifier: String) -> Effect<Action> {
        .run { send in
            do {
                let sessions = try await persistence.sessions(bundleIdentifier)
                await send(.sessionsLoaded(sessions))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    func loadWindows(sessionID: UUID) -> Effect<Action> {
        .run { send in
            do {
                let windows = try await persistence.windows(sessionID)
                await send(.windowsLoaded(windows))
            } catch {
                await send(.loadingFailed(error.localizedDescription))
            }
        }
    }

    func loadTimelineGraph(sessionID: UUID) -> Effect<Action> {
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
