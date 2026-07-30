import AppKit
import Combine
import ComposableArchitecture
import Defaults
import IssueReporting
import LaunchAtLogin
import SFSafeSymbols
import Sparkle
import SwiftUI
import TranslateKit

struct MenuBarView: View {
    @Bindable var store: StoreOf<AppFeature>
    let libraryWindowID: String
    let updater: SPUUpdater

    @Environment(\.openWindow) private var openWindow
    @State private var selectedImageFormat = Defaults[.captureImageFormat]
    @State private var selectedHEICQuality = Defaults[.captureHEICQuality]
    @State private var autoCompactOnClose = Defaults[.autoCompactOnSessionClose]
    @State private var selectedCompactionQuality = Defaults[.compactionQuality]

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

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
            compactionMenu()
        }

        Section(totalScreenshotCountTitle) {
            LaunchAtLogin.Toggle {
                Text("Launch at Login")
            }

            CheckForUpdatesButton(updater: updater)

            Text("Version \(shortVersion) (\(buildVersion))")
                .foregroundStyle(.secondary)

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
                autoCompactOnClose = Defaults[.autoCompactOnSessionClose]
                selectedCompactionQuality = Defaults[.compactionQuality]
                applyScreenshotQualityPreset(selectedScreenshotQualityPreset)
            }
        }
    }

    @ViewBuilder
    private func frontmostAppSection() -> some View {
        if let context = frontmostAppContext {
            Section(context.application.displayName) {
                if let config = context.config {
                    Label(
                        frontmostCaptureStatusTitle(context),
                        systemSymbol: context.isCapturing ? .recordCircle : .pauseCircle
                    )

                    Picker("Capture Mode", selection: captureModeBinding(for: context.application.bundleIdentifier)) {
                        Text("Auto Capture")
                            .tag(CaptureMode.auto)

                        Text("Manual Capture")
                            .tag(CaptureMode.manual)
                    }

                    frontmostCaptureControl(context, config: config)

                    Button("Remove \(context.application.displayName) from Whitelist", systemSymbol: .minusCircle) {
                        removeFromWhitelist(context.application)
                    }
                } else {
                    Button("Add \(context.application.displayName) to Whitelist", systemSymbol: .plusCircle) {
                        addToWhitelist(context.application)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func frontmostCaptureControl(
        _ context: FrontmostAppContext,
        config: WhitelistedAppConfig
    ) -> some View {
        switch config.captureMode {
        case .auto:
            Toggle(
                "Auto Capture",
                isOn: autoCaptureBinding(for: context.application.bundleIdentifier)
            )

        case .manual:
            Button(
                context.isCapturing ? "Stop Capture" : "Start Capture",
                systemSymbol: context.isCapturing ? .stopFill : .recordCircle
            ) {
                toggleCapture(for: context)
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
            if selectedScreenshotQualityPreset == preset {
                Text(verbatim: "✓ ") + Text(preset.title)
            } else {
                Text(preset.title)
            }
            Text(preset.subtitle)
        }
    }

    @ViewBuilder
    private func compactionMenu() -> some View {
        Menu {
            Toggle("Auto-Compact on Session Close", isOn: autoCompactBinding)

            Section("Compaction Quality") {
                ForEach(Self.compactionQualityPresets) { preset in
                    compactionQualityButton(preset)
                }
            }
        } label: {
            Label("Video Compaction", systemSymbol: .archivebox)
        }
    }

    @ViewBuilder
    private func compactionQualityButton(_ preset: CompactionQualityPreset) -> some View {
        Button {
            applyCompactionQuality(preset.quality)
        } label: {
            if abs(selectedCompactionQuality - preset.quality) < 0.001 {
                Text(verbatim: "✓ ") + Text(preset.title)
            } else {
                Text(preset.title)
            }
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

    private var frontmostAppContext: FrontmostAppContext? {
        guard let application = frontmostApplication else {
            return nil
        }

        return FrontmostAppContext(
            application: application,
            config: whitelistConfig(for: application.bundleIdentifier),
            isCapturing: store.captureEngine.activeSessions[application.bundleIdentifier] != nil
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

    private func frontmostCaptureStatusTitle(_ context: FrontmostAppContext) -> String {
        if context.isCapturing {
            return #tk("Capturing")
        }

        switch context.config?.captureMode {
        case .auto:
            return context.config?.isEnabled == true ? #tk("Auto Capture Ready") : #tk("Auto Capture Paused")
        case .manual:
            return #tk("Manual Capture Stopped")
        case nil:
            return #tk("Not Whitelisted")
        }
    }

    private func autoCaptureBinding(for bundleIdentifier: String) -> Binding<Bool> {
        Binding(
            get: {
                whitelistConfig(for: bundleIdentifier)?.isEnabled ?? false
            },
            set: {
                store.send(.whitelistEnabledChanged(bundleIdentifier, $0))
            }
        )
    }

    private func captureModeBinding(for bundleIdentifier: String) -> Binding<CaptureMode> {
        Binding(
            get: {
                whitelistConfig(for: bundleIdentifier)?.captureMode ?? .auto
            },
            set: {
                store.send(.whitelistCaptureModeChanged(bundleIdentifier, $0))
            }
        )
    }

    private func addToWhitelist(_ application: RunningApplication) {
        store.send(.captureEngine(.runningApplicationRegistered(application)))
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
        store.send(.captureEngine(.runningApplicationRegistered(application)))
        store.send(
            .removeWhitelistButtonTapped(application.bundleIdentifier)
        )
    }

    private func toggleCapture(for context: FrontmostAppContext) {
        if context.isCapturing {
            store.send(.captureEngine(.captureStop(context.application.bundleIdentifier)))
        } else {
            store.send(.captureEngine(.runningApplicationRegistered(context.application)))
            store.send(.captureEngine(.captureStart(context.application.bundleIdentifier)))
        }
    }

    private func applyScreenshotQualityPreset(_ preset: ScreenshotQualityPreset) {
        selectedImageFormat = preset.format
        selectedHEICQuality = preset.heicQuality
        Defaults[.captureImageFormat] = preset.format
        Defaults[.captureHEICQuality] = preset.heicQuality
    }

    private var autoCompactBinding: Binding<Bool> {
        Binding(
            get: { autoCompactOnClose },
            set: {
                autoCompactOnClose = $0
                Defaults[.autoCompactOnSessionClose] = $0
            }
        )
    }

    private func applyCompactionQuality(_ quality: Double) {
        selectedCompactionQuality = quality
        Defaults[.compactionQuality] = quality
    }

    private struct ScreenshotQualityPreset: Equatable, Identifiable {
        var id: String
        var title: LocalizedStringKey
        var subtitle: LocalizedStringKey
        var format: CaptureImageFormat
        var heicQuality: Double
    }

    private struct CompactionQualityPreset: Equatable, Identifiable {
        var id: String
        var title: LocalizedStringKey
        var subtitle: LocalizedStringKey
        var quality: Double
    }

    private struct FrontmostAppContext {
        var application: RunningApplication
        var config: WhitelistedAppConfig?
        var isCapturing: Bool
    }

    private static let defaultScreenshotQualityPreset = ScreenshotQualityPreset(
        id: "balanced",
        title: "Balanced",
        subtitle: "HEIC, good clarity with moderate file size",
        format: .heic,
        heicQuality: 0.82
    )

    private static let pngScreenshotQualityPreset = ScreenshotQualityPreset(
        id: "png",
        title: "Lossless PNG",
        subtitle: "Largest files, exact pixels",
        format: .png,
        heicQuality: defaultScreenshotQualityPreset.heicQuality
    )

    private static let screenshotQualityPresets = [
        ScreenshotQualityPreset(
            id: "compact",
            title: "Compact",
            subtitle: "HEIC, smaller files with lighter detail",
            format: .heic,
            heicQuality: 0.60
        ),
        defaultScreenshotQualityPreset,
        ScreenshotQualityPreset(
            id: "clear",
            title: "Clear",
            subtitle: "HEIC, sharper frames with larger files",
            format: .heic,
            heicQuality: 0.95
        ),
        pngScreenshotQualityPreset,
    ]

    private static let compactionQualityPresets = [
        CompactionQualityPreset(
            id: "smaller",
            title: "Smaller",
            subtitle: "Around 20× smaller, slight detail loss",
            quality: 0.5
        ),
        CompactionQualityPreset(
            id: "balanced",
            title: "Balanced",
            subtitle: "Around 11× smaller, near-lossless",
            quality: 0.65
        ),
        CompactionQualityPreset(
            id: "higher",
            title: "Higher Quality",
            subtitle: "Larger videos, crisper frames",
            quality: 0.8
        ),
    ]
}

private struct CheckForUpdatesButton: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…", systemSymbol: .arrowTrianglehead2ClockwiseRotate90) {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

private final class CheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
