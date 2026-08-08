import Foundation

/// A restartable, bounded source of ordered export descriptors. The encoder walks it once to
/// determine its canvas and again to encode, without materializing the complete library scope.
nonisolated struct ExportFrameStream: @unchecked Sendable {
    let selection: FrameSelection
    let count: Int
    private let makeStream: @Sendable () -> AsyncThrowingStream<ExportFrame, Error>

    init(
        selection: FrameSelection,
        count: Int,
        makeStream: @escaping @Sendable () -> AsyncThrowingStream<ExportFrame, Error>
    ) {
        self.selection = selection
        self.count = max(0, count)
        self.makeStream = makeStream
    }

    func stream() -> AsyncThrowingStream<ExportFrame, Error> {
        makeStream()
    }
}

/// A request to encode an ordered stream of screenshots into a timelapse video.
nonisolated struct TimelapseExportRequest: Equatable {
    var source: ExportFrameStream
    var destinationURL: URL
    var codec: TimelapseVideoCodec
    var container: TimelapseVideoContainer
    var framesPerSecond: Int
    var interpolationFrames: Int
    var maxOutputDimension: Int?
    var timestampOverlay: Bool
    init(
        source: ExportFrameStream,
        destinationURL: URL,
        codec: TimelapseVideoCodec,
        container: TimelapseVideoContainer,
        framesPerSecond: Int,
        interpolationFrames: Int,
        maxOutputDimension: Int? = nil,
        timestampOverlay: Bool = false
    ) {
        self.source = source
        self.destinationURL = destinationURL
        self.codec = codec
        self.container = container
        self.framesPerSecond = framesPerSecond
        self.interpolationFrames = interpolationFrames
        self.maxOutputDimension = maxOutputDimension
        self.timestampOverlay = timestampOverlay
    }

    /// Bounded compatibility entry point for focused encoder tests and the legacy optimizer.
    init(
        frames: [ExportFrame],
        destinationURL: URL,
        codec: TimelapseVideoCodec,
        container: TimelapseVideoContainer,
        framesPerSecond: Int,
        interpolationFrames: Int,
        maxOutputDimension: Int? = nil,
        timestampOverlay: Bool = false
    ) {
        let source = ExportFrameStream(selection: .ids([]), count: frames.count) {
            AsyncThrowingStream { continuation in
                for frame in frames {
                    continuation.yield(frame)
                }
                continuation.finish()
            }
        }
        self.init(
            source: source,
            destinationURL: destinationURL,
            codec: codec,
            container: container,
            framesPerSecond: framesPerSecond,
            interpolationFrames: interpolationFrames,
            maxOutputDimension: maxOutputDimension,
            timestampOverlay: timestampOverlay
        )
    }

    /// Total frames the encoder will emit: one per screenshot plus the inserted crossfade
    /// frames between each consecutive pair. Single source of truth shared by the encoder and
    /// the export progress UI.
    var outputFrameCount: Int {
        Self.outputFrameCount(sourceFrames: source.count, interpolationFrames: interpolationFrames)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source.selection == rhs.source.selection
            && lhs.source.count == rhs.source.count
            && lhs.destinationURL == rhs.destinationURL
            && lhs.codec == rhs.codec
            && lhs.container == rhs.container
            && lhs.framesPerSecond == rhs.framesPerSecond
            && lhs.interpolationFrames == rhs.interpolationFrames
            && lhs.maxOutputDimension == rhs.maxOutputDimension
            && lhs.timestampOverlay == rhs.timestampOverlay
    }

    static func outputFrameCount(sourceFrames: Int, interpolationFrames: Int) -> Int {
        guard sourceFrames > 1 else { return max(0, sourceFrames) }
        let interpolation = max(0, interpolationFrames)
        return sourceFrames + (sourceFrames - 1) * interpolation
    }
}
