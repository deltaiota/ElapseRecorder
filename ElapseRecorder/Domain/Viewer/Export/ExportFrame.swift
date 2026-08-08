import CoreGraphics
import Foundation

/// One source screenshot to include in a timelapse export, with its known pixel dimensions when
/// available. Carrying dimensions lets the encoder size the video canvas without opening every
/// file first; a zero dimension means "unknown" (e.g. a record captured before dimensions were
/// tracked), in which case the encoder falls back to reading the file's metadata.
nonisolated struct ExportFrame: Equatable {
    var url: URL
    var pixelWidth: Int
    var pixelHeight: Int
    /// When the screenshot was captured, used for the optional timestamp overlay.
    var capturedAt: Date
    /// 64-bit difference hash, used by the optional export-time near-duplicate filter.
    var perceptualHash: UInt64
    /// When set, pixels come from this video segment at the persisted presentation timestamp.
    var videoURL: URL?
    var videoFrameIndex: Int?
    var videoPTSValue: Int64?
    var videoPTSTimescale: Int32?

    init(
        url: URL,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        capturedAt: Date = Date(timeIntervalSince1970: 0),
        perceptualHash: UInt64 = 0,
        videoURL: URL? = nil,
        videoFrameIndex: Int? = nil,
        videoPTSValue: Int64? = nil,
        videoPTSTimescale: Int32? = nil
    ) {
        self.url = url
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capturedAt = capturedAt
        self.perceptualHash = perceptualHash
        self.videoURL = videoURL
        self.videoFrameIndex = videoFrameIndex
        self.videoPTSValue = videoPTSValue
        self.videoPTSTimescale = videoPTSTimescale
    }

    var frameSource: FrameSource {
        guard let videoURL, let videoPTSValue, let videoPTSTimescale, videoPTSTimescale > 0 else {
            return .file(url)
        }
        return .videoFrame(
            video: videoURL,
            presentationTime: FramePresentationTime(value: videoPTSValue, timescale: videoPTSTimescale)
        )
    }

    var knownPixelSize: CGSize? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
}
