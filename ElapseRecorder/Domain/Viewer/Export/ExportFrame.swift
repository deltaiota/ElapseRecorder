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

    init(url: URL, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.url = url
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var knownPixelSize: CGSize? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
}
