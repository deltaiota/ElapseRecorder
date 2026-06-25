import Foundation

/// An output container/codec choice for an exported timelapse. AVFoundation-specific
/// mappings live in the export dependency layer to keep the domain free of AVFoundation.
nonisolated enum TimelapseVideoFormat: String, CaseIterable, Equatable, Identifiable, Codable {
    case mp4H264
    case movH264
    case movHEVC

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .mp4H264:
            "MP4 · H.264"
        case .movH264:
            "MOV · H.264"
        case .movHEVC:
            "MOV · HEVC"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4H264:
            "mp4"
        case .movH264, .movHEVC:
            "mov"
        }
    }

    static let `default` = TimelapseVideoFormat.mp4H264
}
