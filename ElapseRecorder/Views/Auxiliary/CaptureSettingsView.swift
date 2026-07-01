import SFSafeSymbols
import SwiftUI

/// Capture interval + mode inspector for the selected app, shown below the session list.
struct CaptureSettingsView: View {
    let context: Context
    let defaultCaptureInterval: TimeInterval
    let actions: ViewerView.Actions

    var body: some View {
        HStack {
            if context.isWhitelisted {
                VStack(spacing: 12) {
                    captureIntervalSettings()
                    captureModeSettings()
                }
            } else {
                Label("Whitelist this app to configure capture.", systemSymbol: .minusCircle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func captureIntervalSettings() -> some View {
        VStack(alignment: .leading) {
            Label("Capture Interval", systemSymbol: .timer)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Stepper(
                    value: captureIntervalSecondsBinding,
                    in: Self.captureIntervalSecondsRange,
                    step: 1
                ) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Every")

                        TextField(
                            "Seconds",
                            value: captureIntervalSecondsBinding,
                            format: .number
                        )
                        .monospaced()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                        .textFieldStyle(.plain)

                        Text("s", comment: "Time unit suffix for seconds")
                    }
                }
                .controlSize(.small)
                .fixedSize()

                Spacer(minLength: 12)

                Slider(
                    value: captureIntervalPresetBinding,
                    in: Self.captureIntervalPresetIndexRange,
                    step: 1
                ) {
                    Text("Capture Interval")
                } minimumValueLabel: {
                    Text("1s", comment: "A minimum capture interval of 1 second")
                } maximumValueLabel: {
                    Text("1h", comment: "A maximum capture interval of 1 hour")
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func captureModeSettings() -> some View {
        VStack(alignment: .leading) {
            Label("Capture Mode", systemSymbol: .camera)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Capture Mode", selection: captureModeBinding) {
                    Text("Auto")
                        .tag(CaptureMode.auto)

                    Text("Manual")
                        .tag(CaptureMode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 12)

                captureModeControl()
            }
        }
    }

    @ViewBuilder
    private func captureModeControl() -> some View {
        switch context.whitelistConfig?.captureMode {
        case .auto:
            if context.whitelistConfig?.isEnabled == true {
                Button {
                    actions.setCaptureState(context.app, false)
                } label: {
                    Text("Pause")

                    Image(systemSymbol: .pauseFill)
                }
            } else {
                Button {
                    actions.setCaptureState(context.app, true)
                } label: {
                    Text("Resume")

                    Image(systemSymbol: .playFill)
                }
            }

        case .manual:
            Group {
                if context.isCapturing {
                    Button {
                        actions.stopCapture(context.app)
                    } label: {
                        Text("Stop")

                        Image(systemSymbol: .stopCircle)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        actions.startCapture(context.app)
                    } label: {
                        Text("Start")

                        Image(systemSymbol: .recordCircle)
                    }
                }
            }
            .disabled(!context.isRunning)

        case nil:
            EmptyView()
        }
    }

    // MARK: Bindings

    private var captureInterval: TimeInterval {
        context.whitelistConfig?.captureInterval ?? defaultCaptureInterval
    }

    private var captureIntervalSecondsBinding: Binding<Int> {
        Binding(
            get: { Int(captureInterval) },
            set: { actions.setCaptureInterval(context.app, TimeInterval($0)) }
        )
    }

    private var captureModeBinding: Binding<CaptureMode> {
        Binding(
            get: { context.whitelistConfig?.captureMode ?? .auto },
            set: { actions.setCaptureMode(context.app, $0) }
        )
    }

    private var captureIntervalPresetBinding: Binding<Double> {
        Binding(
            get: { Double(nearestCaptureIntervalPresetIndex(for: captureInterval)) },
            set: { index in
                let clampedIndex = min(
                    max(Int(index.rounded()), 0),
                    Self.captureIntervalPresetSeconds.count - 1
                )
                actions.setCaptureInterval(context.app, Self.captureIntervalPresetSeconds[clampedIndex])
            }
        )
    }

    private func nearestCaptureIntervalPresetIndex(for interval: TimeInterval) -> Int {
        Self.captureIntervalPresetSeconds
            .enumerated()
            .min { lhs, rhs in
                abs(lhs.element - interval) < abs(rhs.element - interval)
            }?
            .offset ?? 0
    }

    private static let captureIntervalSecondsRange: ClosedRange<Int> = 1 ... 3600
    private static let captureIntervalPresetSeconds: [TimeInterval] = [
        1,
        5,
        15,
        30,
        60,
        300,
        900,
        3600,
    ]
    private static let captureIntervalPresetIndexRange = 0 ... Double(captureIntervalPresetSeconds.count - 1)
}

extension CaptureSettingsView {
    struct Context: Equatable {
        var app: AppCaptureSummary
        var whitelistConfig: WhitelistedAppConfig?
        var isRunning: Bool
        var isCapturing: Bool

        var isWhitelisted: Bool {
            whitelistConfig != nil
        }
    }
}

#Preview {
    CaptureSettingsView(
        context: CaptureSettingsView.Context(
            app: AppCaptureSummary(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit", sessionCount: 3, screenshotCount: 128, lastCapturedAt: .now),
            whitelistConfig: WhitelistedAppConfig(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit", captureInterval: 5, isEnabled: true),
            isRunning: true,
            isCapturing: true
        ),
        defaultCaptureInterval: 5,
        actions: ViewerView.Actions()
    )
    .padding()
    .frame(width: 380)
}
