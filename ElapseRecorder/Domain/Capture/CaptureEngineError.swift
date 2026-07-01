import Foundation

nonisolated enum CaptureEngineError: Error, Equatable, LocalizedError {
    case screenRecordingPermissionDenied
    case sessionNotFound(UUID)
    case windowCaptureFailed(systemWindowID: Int)
    case fileWriteFailed(URL)
    case persistenceUnavailable

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            String(localized: "Screen Recording permission is required before Elapse Recorder can capture windows.")
        case let .sessionNotFound(id):
            String(localized: "Capture session \(id.uuidString) could not be found.")
        case let .windowCaptureFailed(systemWindowID):
            String(localized: "Window \(systemWindowID) could not be captured.")
        case let .fileWriteFailed(url):
            String(localized: "Screenshot could not be written to \(url.path).")
        case .persistenceUnavailable:
            String(localized: "Capture metadata storage is unavailable.")
        }
    }
}
