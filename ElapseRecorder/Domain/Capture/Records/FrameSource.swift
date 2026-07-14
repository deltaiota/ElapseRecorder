import Foundation

/// Where a frame's pixels live: a standalone image file, or a specific frame inside a compacted
/// window video. Lets thumbnail loading, Quick Look, and export resolve pixels uniformly whether
/// or not a session has been compacted.
nonisolated enum FrameSource: Equatable, Hashable {
    case file(URL)
    case videoFrame(video: URL, index: Int)
}

extension ScreenshotRecord {
    var frameSource: FrameSource {
        if let videoURL, let videoFrameIndex {
            .videoFrame(video: videoURL, index: videoFrameIndex)
        } else {
            .file(fileURL)
        }
    }
}
