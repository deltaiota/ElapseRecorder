import AppKit
import ComposableArchitecture
import Defaults
import IssueReporting
import LaunchAtLogin
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct MenuBarView: View {
    @Bindable var store: StoreOf<AppFeature>
    let libraryWindowID: String

    @Environment(\.openWindow) private var openWindow
    @State private var selectedImageFormat = Defaults[.captureImageFormat]
    @State private var selectedHEICQuality = Defaults[.captureHEICQuality]

    var body: some View {
        frontmostAppSection()

        Divider()

        Section(captureCountTitle) {
            Button("Show Library", systemSymbol: .rectangleStack) {
                openWindow(id: libraryWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("l")

            screenshotQualityMenu()
        }

        Section(totalScreenshotCountTitle) {
            LaunchAtLogin.Toggle()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            .task {
                guard !isTesting else {
                    return
                }
                
                await store.send(.task).finish()
            }
            .onAppear {
                selectedImageFormat = Defaults[.captureImageFormat]
                selectedHEICQuality = Defaults[.captureHEICQuality]
                applyScreenshotQualityPreset(selectedScreenshotQualityPreset)
            }
        }
    }

    @ViewBuilder
    private func frontmostAppSection() -> some View {
        if let frontmostApplication {
            Section(frontmostApplication.displayName) {
                if let config = whitelistConfig(for: frontmostApplication.bundleIdentifier) {
                    Label(
                        frontmostCaptureStatusTitle(config),
                        systemSymbol: isCapturing(frontmostApplication) ? .recordCircle : .pauseCircle
                    )

                    Picker("Capture Mode", selection: captureModeBinding(for: frontmostApplication)) {
                        Text("Auto Capture")
                            .tag(CaptureMode.auto)

                        Text("Manual Capture")
                            .tag(CaptureMode.manual)
                    }

                    frontmostCaptureControl(frontmostApplication, config: config)

                    Button("Remove \(frontmostApplication.displayName) from Whitelist", systemSymbol: .minusCircle) {
                        removeFromWhitelist(frontmostApplication)
                    }
                } else {
                    Button("Add \(frontmostApplication.displayName) to Whitelist", systemSymbol: .plusCircle) {
                        addToWhitelist(frontmostApplication)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func frontmostCaptureControl(
        _ application: RunningApplication,
        config: WhitelistedAppConfig
    ) -> some View {
        switch config.captureMode {
        case .auto:
            Toggle(
                "Auto Capture",
                isOn: Binding(
                    get: { config.isEnabled },
                    set: { store.send(.whitelistEnabledChanged(application.bundleIdentifier, $0)) }
                )
            )

        case .manual:
            let isCapturing = isCapturing(application)
            Button(
                isCapturing ? "Stop Capture" : "Start Capture",
                systemSymbol: isCapturing ? .stopFill : .recordCircle
            ) {
                if isCapturing {
                    store.send(.captureEngine(.manualCaptureStop(application.bundleIdentifier)))
                } else {
                    store.send(.captureEngine(.runningApplicationsLoaded([application])))
                    store.send(.captureEngine(.manualCaptureStart(application.bundleIdentifier)))
                }
            }
        }
    }

    @ViewBuilder
    private func screenshotQualityMenu() -> some View {
        Menu {
            ForEach(Self.screenshotQualityPresets) { preset in
                screenshotQualityButton(preset)
            }
        } label: {
            Label("Screenshot Quality", systemSymbol: .sliderHorizontal3)
        }
    }

    @ViewBuilder
    private func screenshotQualityButton(_ preset: ScreenshotQualityPreset) -> some View {
        Button {
            applyScreenshotQualityPreset(preset)
        } label: {
            Text(selectedScreenshotQualityPreset == preset ? "✓ \(preset.title)" : preset.title)
            Text(preset.subtitle)
        }
    }

    private var frontmostApplication: RunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier
        else {
            return nil
        }

        return RunningApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }

    private var captureCountTitle: String {
        #tk("Capturing \(store.captureEngine.activeSessions.count) Apps")
    }

    private var totalScreenshotCountTitle: String {
        #tk("Total \(store.viewer.apps.reduce(0) { $0 + $1.screenshotCount }) Screenshots")
    }

    private var selectedScreenshotQualityPreset: ScreenshotQualityPreset {
        if selectedImageFormat == .png {
            return Self.pngScreenshotQualityPreset
        }

        return Self.screenshotQualityPresets.first {
            $0.format == selectedImageFormat && $0.heicQuality == selectedHEICQuality
        } ?? Self.defaultScreenshotQualityPreset
    }

    private func whitelistConfig(for bundleIdentifier: String) -> WhitelistedAppConfig? {
        store.whitelistConfigs.first { $0.bundleIdentifier == bundleIdentifier }
    }

    private func isCapturing(_ application: RunningApplication) -> Bool {
        store.captureEngine.activeSessions[application.bundleIdentifier] != nil
    }

    private func frontmostCaptureStatusTitle(_ config: WhitelistedAppConfig) -> String {
        if store.captureEngine.activeSessions[config.bundleIdentifier] != nil {
            return #tk("Capturing")
        }

        switch config.captureMode {
        case .auto:
            return config.isEnabled ? #tk("Auto Capture Ready") : #tk("Auto Capture Paused")
        case .manual:
            return #tk("Manual Capture Stopped")
        }
    }

    private func captureModeBinding(for application: RunningApplication) -> Binding<CaptureMode> {
        Binding(
            get: {
                whitelistConfig(for: application.bundleIdentifier)?.captureMode ?? .auto
            },
            set: {
                store.send(.whitelistCaptureModeChanged(application.bundleIdentifier, $0))
            }
        )
    }

    private func addToWhitelist(_ application: RunningApplication) {
        store.send(.captureEngine(.runningApplicationsLoaded([application])))
        store.send(
            .addWhitelistConfigsButtonTapped([
                WhitelistedAppConfig(
                    bundleIdentifier: application.bundleIdentifier,
                    displayName: application.displayName,
                    captureInterval: store.draftIntervalSeconds,
                    isEnabled: true
                ),
            ])
        )
    }

    private func removeFromWhitelist(_ application: RunningApplication) {
        store.send(.captureEngine(.runningApplicationsLoaded([application])))
        store.send(
            .removeWhitelistButtonTapped(application.bundleIdentifier)
        )
    }

    private func applyScreenshotQualityPreset(_ preset: ScreenshotQualityPreset) {
        selectedImageFormat = preset.format
        selectedHEICQuality = preset.heicQuality
        Defaults[.captureImageFormat] = preset.format
        Defaults[.captureHEICQuality] = preset.heicQuality
    }

    private struct ScreenshotQualityPreset: Equatable, Identifiable {
        var id: String {
            title
        }

        var title: String
        var subtitle: String
        var format: CaptureImageFormat
        var heicQuality: Double
    }

    private static let defaultScreenshotQualityPreset = ScreenshotQualityPreset(
        title: "Balanced",
        subtitle: "HEIC, good clarity with moderate file size",
        format: .heic,
        heicQuality: 0.82
    )

    private static let pngScreenshotQualityPreset = ScreenshotQualityPreset(
        title: "Lossless PNG",
        subtitle: "Largest files, exact pixels",
        format: .png,
        heicQuality: defaultScreenshotQualityPreset.heicQuality
    )

    private static let screenshotQualityPresets = [
        ScreenshotQualityPreset(
            title: "Compact",
            subtitle: "HEIC, smaller files with lighter detail",
            format: .heic,
            heicQuality: 0.60
        ),
        defaultScreenshotQualityPreset,
        ScreenshotQualityPreset(
            title: "Clear",
            subtitle: "HEIC, sharper frames with larger files",
            format: .heic,
            heicQuality: 0.95
        ),
        pngScreenshotQualityPreset,
    ]
}
