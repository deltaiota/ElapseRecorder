import Foundation

/// Exact presentation coordinate within an immutable video asset.
nonisolated struct FramePresentationTime: Equatable, Hashable {
    let value: Int64
    let timescale: Int32

    init(value: Int64, timescale: Int32) {
        precondition(timescale > 0)
        self.value = value
        self.timescale = timescale
    }
}

/// Where a frame's pixels live: a standalone image file, or an exact rational timestamp inside
/// an immutable video. The timescale is persisted per frame and is never inferred by the reader.
nonisolated enum FrameSource: Equatable, Hashable {
    case file(URL)
    case videoFrame(video: URL, presentationTime: FramePresentationTime)
}

extension ScreenshotRecord {
    var frameSource: FrameSource {
        guard let videoURL, let videoPTSValue, let videoPTSTimescale, videoPTSTimescale > 0 else {
            return .file(fileURL)
        }
        return .videoFrame(
            video: videoURL,
            presentationTime: FramePresentationTime(value: videoPTSValue, timescale: videoPTSTimescale)
        )
    }
}
