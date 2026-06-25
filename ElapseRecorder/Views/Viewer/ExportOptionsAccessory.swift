import SwiftUI

/// Shared state for the export save-panel accessory. A reference type so the AppKit save
/// panel can read the final choices back after the SwiftUI accessory has mutated them.
@MainActor
@Observable
final class ExportAccessoryModel {
    var format: TimelapseVideoFormat
    var fpsChoice: FPSChoice
    var customFPS: Int

    static let presetFPS = [8, 12, 24, 30, 60]

    enum FPSChoice: Hashable {
        case preset(Int)
        case custom
    }

    init(options: ExportOptions = .default) {
        format = options.format
        customFPS = options.framesPerSecond
        fpsChoice = Self.presetFPS.contains(options.framesPerSecond)
            ? .preset(options.framesPerSecond)
            : .custom
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
        ExportOptions(format: format, framesPerSecond: resolvedFramesPerSecond)
    }
}

/// SwiftUI options shown as the accessory view of the export save panel: output format and
/// frame rate (a picker with a Custom option that reveals a numeric field).
struct ExportOptionsAccessory: View {
    @Bindable var model: ExportAccessoryModel
    var onFormatChange: (TimelapseVideoFormat) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Format")
                    .gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)

                Picker("Format", selection: $model.format) {
                    ForEach(TimelapseVideoFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .onChange(of: model.format) { _, newValue in
                    onFormatChange(newValue)
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

#Preview {
    ExportOptionsAccessory(model: ExportAccessoryModel(), onFormatChange: { _ in })
}
