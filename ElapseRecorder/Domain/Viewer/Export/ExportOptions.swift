import Foundation

/// User-chosen settings for a timelapse export.
nonisolated struct ExportOptions: Equatable {
    var format: TimelapseVideoFormat
    var framesPerSecond: Int

    static let `default` = ExportOptions(format: .default, framesPerSecond: 12)
}

/// The result of the export save panel: where to write and with what settings.
nonisolated struct ExportSelection: Equatable {
    var destinationURL: URL
    var options: ExportOptions
}
