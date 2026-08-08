import Foundation

nonisolated struct ScreenshotRecord: Equatable, Identifiable {
    var id: UUID
    var windowID: UUID
    var sessionID: UUID
    var capturedAt: Date
    var fileURL: URL
    var fileSizeBytes: Int
    /// Pixel dimensions of the encoded frame. Zero means "unknown" (records written before
    /// dimensions were tracked). Used to size the export canvas without opening every file.
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// 64-bit difference hash (dHash) of the frame, used to detect near-identical frames.
    /// Zero means "not computed".
    var perceptualHash: UInt64 = 0
    /// When set, this frame lives inside a compacted HEVC video rather than at `fileURL`.
    /// Pixels are decoded from `videoURL` at `videoFrameIndex`. `fileURL` may no longer exist.
    var videoURL: URL? = nil
    var videoFrameIndex: Int? = nil
    /// Exact rational presentation coordinate for V2 video segments.
    var videoPTSValue: Int64? = nil
    var videoPTSTimescale: Int32? = nil

    /// True when this frame's pixels are stored in a compacted video rather than a standalone file.
    var isCompacted: Bool {
        videoURL != nil
    }
}
