import Foundation

/// User-chosen settings for a timelapse export.
nonisolated struct ExportOptions: Equatable {
    var codec: TimelapseVideoCodec
    var container: TimelapseVideoContainer
    var framesPerSecond: Int
    /// Number of crossfade frames inserted between each pair of screenshots (0 = none).
    var interpolationFrames: Int
    /// Longest-side pixel cap for the output video; `nil` keeps the source resolution.
    var maxOutputDimension: Int?
    /// Burn each frame's capture time into the video.
    var timestampOverlay: Bool

    init(
        codec: TimelapseVideoCodec,
        container: TimelapseVideoContainer,
        framesPerSecond: Int,
        interpolationFrames: Int,
        maxOutputDimension: Int? = nil,
        timestampOverlay: Bool = false
    ) {
        self.codec = codec
        self.container = container
        self.framesPerSecond = framesPerSecond
        self.interpolationFrames = interpolationFrames
        self.maxOutputDimension = maxOutputDimension
        self.timestampOverlay = timestampOverlay
    }

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
