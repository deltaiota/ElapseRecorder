import SwiftUI

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

    static let presetFPS = [8, 12, 24, 30, 60]

    enum FPSChoice: Hashable {
        case preset(Int)
        case custom
    }

    init(options: ExportOptions = .default) {
        codec = options.codec
        container = options.container
        customFPS = options.framesPerSecond
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
        ExportOptions(codec: codec, container: container, framesPerSecond: resolvedFramesPerSecond)
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

                    ContainerSegmentedPicker(
                        selection: $model.container,
                        allowed: model.codec.allowedContainers
                    )
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
                            Text("\(fps) fps").tag(ExportAccessoryModel.FPSChoice.preset(fps))
                        }
                        Divider()
                        Text("Custom").tag(ExportAccessoryModel.FPSChoice.custom)
                    }
                    .labelsHidden()
                    .fixedSize()

                    if model.fpsChoice == .custom {
                        TextField("fps", value: $model.customFPS, format: .number)
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                        Text("fps")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

/// A small segmented control over the video containers, greying out (disabling) any the
/// current codec can't use.
private struct ContainerSegmentedPicker: View {
    @Binding var selection: TimelapseVideoContainer
    let allowed: [TimelapseVideoContainer]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimelapseVideoContainer.allCases) { container in
                let isEnabled = allowed.contains(container)
                let isSelected = selection == container

                Button {
                    selection = container
                } label: {
                    Text(container.title)
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .background(
                            isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .foregroundStyle(foreground(isSelected: isSelected, isEnabled: isEnabled))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }

    private func foreground(isSelected: Bool, isEnabled: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        return isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }
}

#Preview {
    ExportOptionsAccessory(model: ExportAccessoryModel(), onContainerChange: { _ in })
}
