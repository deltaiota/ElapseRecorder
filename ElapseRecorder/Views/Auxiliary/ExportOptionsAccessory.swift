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
    var interpolationFrames: Int

    static let presetFPS = [2, 4, 8, 12, 24, 30, 60, 120, 240]
    static let maxInterpolationFrames = 30

    enum FPSChoice: Hashable {
        case preset(Int)
        case custom
    }

    init(options: ExportOptions = .default) {
        codec = options.codec
        container = options.container
        customFPS = options.framesPerSecond
        interpolationFrames = options.interpolationFrames
        fpsChoice = Self.presetFPS.contains(options.framesPerSecond)
            ? .preset(options.framesPerSecond)
            : .custom
        normalizeContainer()
    }

    /// Keep the container valid for the chosen codec (e.g. HEVC can't use MP4 here).
    private func normalizeContainer() {
        if !codec.allowedContainers.contains(container) {
            container = codec.allowedContainers.first ?? .mov
        }
    }

    var resolvedFramesPerSecond: Int {
        switch fpsChoice {
        case let .preset(value):
            value
        case .custom:
            min(240, max(1, customFPS))
        }
    }

    var options: ExportOptions {
        ExportOptions(
            codec: codec,
            container: container,
            framesPerSecond: resolvedFramesPerSecond,
            interpolationFrames: min(Self.maxInterpolationFrames, max(0, interpolationFrames))
        )
    }
}

/// SwiftUI options shown as the accessory view of the export save panel: a codec picker
/// beside an inline container (file extension) picker, and a frame rate picker whose Custom
/// option reveals a numeric field.
struct ExportOptionsAccessory: View {
    @Bindable var model: ExportAccessoryModel
    var onContainerChange: (TimelapseVideoContainer) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
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
                    }
                    .labelsHidden()
                    .fixedSize()

                    if model.fpsChoice == .custom {
                        TextField("fps", value: $model.customFPS, format: .number)
                            .frame(width: 56, height: 20)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("fps")
                        .foregroundStyle(.secondary)
                }
            }

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

                    Text(#tk("\(model.interpolationFrames) crossfade frames").replacing(/^\d+\w*/, with: ""))
                        .foregroundStyle(.secondary)
                }
                .help("Insert this many crossfaded frames between each screenshot for a smoother dissolve.")
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

#Preview {
    ExportOptionsAccessory(model: ExportAccessoryModel(), onContainerChange: { _ in })
}
