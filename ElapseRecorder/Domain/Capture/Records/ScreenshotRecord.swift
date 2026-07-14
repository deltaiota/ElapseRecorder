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
}
