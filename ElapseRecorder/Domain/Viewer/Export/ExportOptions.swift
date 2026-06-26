import Foundation

/// User-chosen settings for a timelapse export.
nonisolated struct ExportOptions: Equatable {
    var codec: TimelapseVideoCodec
    var container: TimelapseVideoContainer
    var framesPerSecond: Int
    /// Number of crossfade frames inserted between each pair of screenshots (0 = none).
    var interpolationFrames: Int

    static let `default` = ExportOptions(
        codec: .default,
        container: .default,
        framesPerSecond: 12,
        interpolationFrames: 0
    )
}

/// The result of the export save panel: where to write and with what settings.
nonisolated struct ExportSelection: Equatable {
    var destinationURL: URL
    var options: ExportOptions
}
