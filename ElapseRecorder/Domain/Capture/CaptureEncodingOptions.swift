import Foundation

nonisolated struct CaptureEncodingOptions: Equatable {
    var format: CaptureImageFormat
    var heicQuality: Double

    static let defaultValue = Self(format: .heic, heicQuality: 0.82)
}
