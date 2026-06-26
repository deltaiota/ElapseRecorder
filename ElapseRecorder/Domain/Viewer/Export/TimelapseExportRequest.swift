import Foundation

/// A request to encode an ordered set of screenshots into a timelapse video.
nonisolated struct TimelapseExportRequest: Equatable {
    var imageURLs: [URL]
    var destinationURL: URL
    var codec: TimelapseVideoCodec
    var container: TimelapseVideoContainer
    var framesPerSecond: Int
}
