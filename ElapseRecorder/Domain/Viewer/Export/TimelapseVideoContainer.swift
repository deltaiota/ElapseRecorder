import Foundation

/// The output file container/extension for an exported timelapse.
nonisolated enum TimelapseVideoContainer: String, CaseIterable, Equatable, Identifiable, Codable {
    case mp4
    case mov

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .mp4:
            "MP4"
        case .mov:
            "MOV"
        }
    }

    var fileExtension: String {
        rawValue
    }

    static let `default` = TimelapseVideoContainer.mp4
}
