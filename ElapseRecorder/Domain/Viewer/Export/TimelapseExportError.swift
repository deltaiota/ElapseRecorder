import Foundation

nonisolated enum TimelapseExportError: Error, Equatable, LocalizedError {
    case noFrames
    case unreadableImage(URL)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFrames:
            "There are no screenshots to export."
        case let .unreadableImage(url):
            "A screenshot could not be read: \(url.lastPathComponent)."
        case let .encodingFailed(message):
            "The timelapse could not be encoded: \(message)."
        }
    }
}
