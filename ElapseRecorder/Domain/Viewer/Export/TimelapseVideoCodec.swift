import Foundation

/// The compression algorithm for an exported timelapse. AVFoundation mappings live in the
/// export dependency layer to keep the domain free of AVFoundation.
nonisolated enum TimelapseVideoCodec: String, CaseIterable, Equatable, Identifiable, Codable {
    case h264
    case hevc

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .h264:
            "H.264"
        case .hevc:
            "HEVC"
        }
    }

    /// Containers this codec can be written into. HEVC is restricted to QuickTime here.
    var allowedContainers: [TimelapseVideoContainer] {
        switch self {
        case .h264:
            [.mp4, .mov]
        case .hevc:
            [.mov]
        }
    }

    static let `default` = TimelapseVideoCodec.h264
}
