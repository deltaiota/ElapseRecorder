import Foundation

nonisolated enum CaptureUnavailableReason: String, Codable, Equatable {
    case windowMinimized

    var title: String {
        switch self {
        case .windowMinimized:
            "Window hidden or unavailable for capture"
        }
    }
}
