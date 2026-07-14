import SwiftUI
import TranslateKit

/// Shared state for the export save-panel accessory. A reference type so the AppKit save
/// panel can read the final choices back after the SwiftUI accessory has mutated them.
@MainActor
@Observable
final class ExportAccessoryModel {
    var codec: TimelapseVideoCodec {
        didSet { normalizeContainer() }
    }

    var container: TimelapseVideoContainer
    var fpsChoice: FPSChoice
    var customFPS: Int
    var targetDurationSeconds: Double
    var interpolationFrames: Int
    var resolutionCap: Int
    var showsTimestamp: Bool
    var trimEnabled: Bool
    var trimStart: Int
    var trimEnd: Int
    var skipSimilarFrames: Bool
    let frameHashes: [UInt64]

    static let presetFPS = [2, 4, 8, 12, 24, 30, 60, 120, 240]
    static let maxInterpolationFrames = 30
    /// Longest-side pixel caps offered in the UI. 0 means "full resolution".
    static let resolutionCaps = [0, 2160, 1440, 1080, 720]

    enum FPSChoice: Hashable {
        case preset(Int)
        case custom
        case targetDuration
    }

    init(options: ExportOptions = .default, frameHashes: [UInt64] = []) {
        codec = options.codec
        container = options.container
        customFPS = options.framesPerSecond
        targetDurationSeconds = 30
        interpolationFrames = options.interpolationFrames
        resolutionCap = options.maxOutputDimension ?? 0
        showsTimestamp = options.timestampOverlay
        self.frameHashes = frameHashes
        trimEnabled = false
        trimStart = 0
        trimEnd = max(0, frameHashes.count - 1)
        skipSimilarFrames = options.skipSimilarFrames
        fpsChoice = Self.presetFPS.contains(options.framesPerSecond)
            ? .preset(options.framesPerSecond)
            : .custom
        normalizeContainer()
    }

    var frameCount: Int {
        frameHashes.count
    }

    /// Keep the container valid for the chosen codec (e.g. HEVC can't use MP4 here).
    private func normalizeContainer() {
        if !codec.allowedContainers.contains(container) {
            container = codec.allowedContainers.first ?? .mov
        }
    }

    /// The trim range clamped to valid bounds, or nil when trimming is off / covers everything.
    var resolvedTrimRange: ClosedRange<Int>? {
        guard trimEnabled, frameCount > 0 else { return nil }
        let lower = min(max(0, trimStart), frameCount - 1)
        let upper = min(max(lower, trimEnd), frameCount - 1)
        guard lower > 0 || upper < frameCount - 1 else { return nil }
        return lower ... upper
    }

    /// Source-frame hashes after applying the trim range.
    private var trimmedHashes: [UInt64] {
        guard frameCount > 0 else { return [] }
        if let range = resolvedTrimRange {
            return Array(frameHashes[range])
        }
        return frameHashes
    }

    /// Number of source frames that survive trim + optional near-duplicate filtering.
    var effectiveSourceCount: Int {
        let hashes = trimmedHashes
        return skipSimilarFrames ? ExportFrameFilter.keptIndices(hashes: hashes).count : hashes.count
    }

    var resolvedInterpolationFrames: Int {
        min(Self.maxInterpolationFrames, max(0, interpolationFrames))
    }

    /// Total frames the export will emit: one per surviving screenshot plus the crossfades.
    var estimatedFrameCount: Int {
        let count = effectiveSourceCount
        guard count > 1 else { return max(0, count) }
        return count + (count - 1) * resolvedInterpolationFrames
    }

    var resolvedFramesPerSecond: Int {
        switch fpsChoice {
        case let .preset(value):
            return value
        case .custom:
            return min(240, max(1, customFPS))
        case .targetDuration:
            let seconds = max(0.1, targetDurationSeconds)
            return min(240, max(1, Int((Double(estimatedFrameCount) / seconds).rounded())))
        }
    }

    var estimatedDuration: Duration {
        guard resolvedFramesPerSecond > 0 else { return .zero }
        return .seconds(Double(estimatedFrameCount) / Double(resolvedFramesPerSecond))
    }

    var options: ExportOptions {
        ExportOptions(
            codec: codec,
            container: container,
            framesPerSecond: resolvedFramesPerSecond,
            interpolationFrames: resolvedInterpolationFrames,
            maxOutputDimension: resolutionCap == 0 ? nil : resolutionCap,
            timestampOverlay: showsTimestamp,
            trimRange: resolvedTrimRange,
            skipSimilarFrames: skipSimilarFrames
        )
    }
}

/// SwiftUI options shown as the accessory view of the export save panel: a codec picker
/// beside an inline container (file extension) picker, and a frame rate picker whose Custom
/// option reveals a numeric field.
struct ExportOptionsAccessory: View {
    @Bindable var model: ExportAccessoryModel
    var onContainerChange: (TimelapseVideoContainer) -> Void
    var onContentSizeChange: (CGSize) -> Void = { _ in }

    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                formatRow()
                frameRateRow()
                interpolationRow()
            }

            DisclosureGroup(isExpanded: $showsAdvanced) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    resolutionRow()
                    timestampRow()
                    framesRow()
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Advanced")
                    .font(.callout)
            }

            Text(estimateText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            onContentSizeChange(size)
        }
    }

    @ViewBuilder
    private func formatRow() -> some View {
        GridRow {
            Text("Format")
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("Codec", selection: $model.codec) {
                    ForEach(TimelapseVideoCodec.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Picker("Container", selection: $model.container) {
                    ForEach(TimelapseVideoContainer.allCases) { container in
                        Text(container.title)
                            .tag(container)
                            .selectionDisabled(!model.codec.allowedContainers.contains(container))
                    }
                }
                .fixedSize()
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            .onChange(of: model.container) { _, newValue in
                onContainerChange(newValue)
            }
        }
    }

    @ViewBuilder
    private func frameRateRow() -> some View {
        GridRow {
            Text("Frame Rate")
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("Frame Rate", selection: $model.fpsChoice) {
                    ForEach(ExportAccessoryModel.presetFPS, id: \.self) { fps in
                        Text("\(fps)").tag(ExportAccessoryModel.FPSChoice.preset(fps))
                    }
                    Divider()
                    Text("Custom").tag(ExportAccessoryModel.FPSChoice.custom)
                    Text("Target length").tag(ExportAccessoryModel.FPSChoice.targetDuration)
                }
                .labelsHidden()
                .fixedSize()

                if model.fpsChoice == .custom {
                    TextField("fps", value: $model.customFPS, format: .number)
                        .frame(width: 56, height: 20)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("fps")
                        .foregroundStyle(.secondary)
                } else if model.fpsChoice == .targetDuration {
                    TextField("seconds", value: $model.targetDurationSeconds, format: .number)
                        .frame(width: 56, height: 20)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("sec")
                        .foregroundStyle(.secondary)
                } else {
                    Text("fps")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func interpolationRow() -> some View {
        GridRow {
            Text("Interpolation")
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)

            HStack {
                Stepper(
                    value: $model.interpolationFrames,
                    in: 0 ... ExportAccessoryModel.maxInterpolationFrames
                ) {
                    TextField(
                        "frames",
                        value: $model.interpolationFrames,
                        format: .number
                    )
                    .frame(width: 44, height: 20)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                }
                .fixedSize()

                Text("crossfade frames")
                    .foregroundStyle(.secondary)
            }
            .help("Insert this many crossfaded frames between each screenshot for a smoother dissolve.")
        }
    }

    @ViewBuilder
    private func resolutionRow() -> some View {
        GridRow {
            Text("Resolution")
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)

            Picker("Resolution", selection: $model.resolutionCap) {
                ForEach(ExportAccessoryModel.resolutionCaps, id: \.self) { cap in
                    Text(resolutionLabel(cap)).tag(cap)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Scale the video down so its longest side fits this many pixels.")
        }
    }

    @ViewBuilder
    private func timestampRow() -> some View {
        GridRow {
            Text("Timestamp")
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)

            Toggle(isOn: $model.showsTimestamp) {
                Text("Show capture time")
            }
            .help("Burn each frame's capture time into the corner of the video.")
        }
    }

    @ViewBuilder
    private func framesRow() -> some View {
        GridRow {
            Text("Frames")
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $model.skipSimilarFrames) {
                    Text("Skip near-duplicate frames")
                }
                .help("Drop frames that barely changed from the previous kept frame. Originals are not deleted.")

                if model.frameCount > 1 {
                    Toggle(isOn: $model.trimEnabled) {
                        Text("Trim range")
                    }

                    if model.trimEnabled {
                        HStack(spacing: 6) {
                            TextField("from", value: $model.trimStart, format: .number)
                                .frame(width: 60, height: 20)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                            Text("to")
                                .foregroundStyle(.secondary)
                            TextField("to", value: $model.trimEnd, format: .number)
                                .frame(width: 60, height: 20)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                            Text("of \(model.frameCount)")
                                .foregroundStyle(.secondary)
                        }
                        .help("Export only frames in this 0-based index range.")
                    }
                }
            }
        }
    }

    private func resolutionLabel(_ cap: Int) -> String {
        cap == 0 ? String(localized: "Full") : String(localized: "\(cap)p")
    }

    private var estimateText: String {
        let duration = model.estimatedDuration.formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
        return #tk("Estimated length: \(duration) · \(model.estimatedFrameCount) frames")
    }
}

#Preview {
    ExportOptionsAccessory(
        model: ExportAccessoryModel(frameHashes: Array(repeating: 0, count: 120)),
        onContainerChange: { _ in }
    )
}
