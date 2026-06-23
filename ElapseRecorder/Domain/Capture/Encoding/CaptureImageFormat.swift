import Foundation

nonisolated enum CaptureImageFormat: String, CaseIterable, Codable, Equatable {
    case heic
    case png

    var fileExtension: String {
        switch self {
        case .heic:
            "heic"
        case .png:
            "png"
        }
    }
}
