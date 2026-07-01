import Foundation

/// A capture-engine diagnostic surfaced in the app's diagnostics list.
///
/// Authored cases carry their parameters so the UI can render a localized string via
/// `resource`, while `.failure` wraps an already-localized system/error description that is
/// shown verbatim.
nonisolated enum CaptureDiagnostic: Equatable {
    case appNotRunning(displayName: String)
    case closedStaleSessions(count: Int)
    case permissionRequired
    case failure(String)

    /// Localizable text for authored diagnostics; `nil` for `.failure` (rendered verbatim).
    var resource: LocalizedStringResource? {
        switch self {
        case let .appNotRunning(displayName):
            "Cannot start capture because \(displayName) is not running."
        case let .closedStaleSessions(count):
            "Closed \(count) stale open capture sessions."
        case .permissionRequired:
            "Screen Recording permission is required before Elapse Recorder can capture windows."
        case .failure:
            nil
        }
    }

    /// Plain-text form used by the reducer for de-duplication and permission-state clearing.
    var message: String {
        switch self {
        case let .failure(message):
            message
        case .appNotRunning, .closedStaleSessions, .permissionRequired:
            String(localized: resource ?? "")
        }
    }
}
