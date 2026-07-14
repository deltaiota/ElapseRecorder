import Foundation

/// A request to encode an ordered set of screenshots into a timelapse video.
nonisolated struct TimelapseExportRequest: Equatable {
    var imageURLs: [URL]
    var destinationURL: URL
    var codec: TimelapseVideoCodec
    var container: TimelapseVideoContainer
    var framesPerSecond: Int
    var interpolationFrames: Int

    /// Total frames the encoder will emit: one per screenshot plus the inserted crossfade
    /// frames between each consecutive pair. Single source of truth shared by the encoder and
    /// the export progress UI.
    var outputFrameCount: Int {
        Self.outputFrameCount(sourceFrames: imageURLs.count, interpolationFrames: interpolationFrames)
    }

    static func outputFrameCount(sourceFrames: Int, interpolationFrames: Int) -> Int {
        guard sourceFrames > 1 else { return max(0, sourceFrames) }
        let interpolation = max(0, interpolationFrames)
        return sourceFrames + (sourceFrames - 1) * interpolation
    }
}
