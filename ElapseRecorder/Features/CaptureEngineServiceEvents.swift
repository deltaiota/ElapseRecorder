import ComposableArchitecture
import Foundation

extension CaptureEngineFeature {
    func reduceServiceEvent(
        _ event: RecordingServiceEvent,
        state: inout State
    ) -> Effect<Action> {
        switch event {
        case let .permissionChanged(status):
            return .send(.permissionResolved(status, nil))

        case let .runningApplicationsChanged(applications):
            return .send(.runningApplicationsLoaded(applications))

        case let .workspaceEvent(event):
            return .send(.workspaceEvent(event))

        case let .sessionOpened(snapshot):
            return sessionOpened(snapshot, state: &state)

        case let .sessionUpdated(snapshot):
            updateSession(snapshot, state: &state)
            return .none

        case let .sessionClosed(handle, _):
            return sessionClosed(handle, state: &state)

        case let .frameCommitted(_, record):
            return .send(.screenshotRecorded(record))

        case .segmentCommitted:
            return .none

        case let .captureUnavailableRecorded(_, record):
            return .send(.captureUnavailableRecorded(record))

        case let .diagnostic(diagnostic):
            return updateDiagnostics(diagnostic, state: &state)

        case let .storageDegraded(degradation):
            return updateStorage(degradation, state: &state)

        case .storageResumed:
            return updateStorage(nil, state: &state)

        case .schedulerDeadlineMissed:
            state.schedulerDeadlineMissCount += 1
            return .none
        }
    }

    private func sessionOpened(_ snapshot: RecordingSessionSnapshot, state: inout State) -> Effect<Action> {
        state.activeSessions[snapshot.handle.bundleIdentifier] = activeSession(from: snapshot)
        return .send(.sessionOpened(snapshot.session, snapshot.application))
    }

    private func updateSession(_ snapshot: RecordingSessionSnapshot, state: inout State) {
        guard state.activeSessions[snapshot.handle.bundleIdentifier]?.session.id == snapshot.handle.sessionID else {
            return
        }
        state.activeSessions[snapshot.handle.bundleIdentifier] = activeSession(from: snapshot)
    }

    private func sessionClosed(_ handle: RecordingSessionHandle, state: inout State) -> Effect<Action> {
        if state.activeSessions[handle.bundleIdentifier]?.session.id == handle.sessionID {
            state.activeSessions[handle.bundleIdentifier] = nil
        }
        return .send(.sessionClosed(handle.bundleIdentifier))
    }

    private func updateDiagnostics(_ diagnostic: CaptureDiagnostic, state: inout State) -> Effect<Action> {
        state.recordDiagnostic(diagnostic)
        return .none
    }

    private func updateStorage(_ degradation: StorageDegradation?, state: inout State) -> Effect<Action> {
        state.storageDegradation = degradation
        return .none
    }

    private func activeSession(from snapshot: RecordingSessionSnapshot) -> State.ActiveSession {
        State.ActiveSession(
            application: snapshot.application,
            config: snapshot.config,
            session: snapshot.session,
            generation: snapshot.handle.generation,
            nextWindowNumber: snapshot.nextWindowNumber,
            windowsBySystemID: snapshot.windowsBySystemID,
            isCaptureInFlight: snapshot.isCaptureInFlight,
            captureUnavailableReason: snapshot.captureUnavailableReason,
            pauseReason: snapshot.pauseReason
        )
    }
}
