import ComposableArchitecture
import SwiftUI

struct ViewerView: View {
    @Bindable var store: StoreOf<ViewerFeature>

    var captureConfiguration = CaptureConfiguration()
    var actions = Actions()

    var body: some View {
        NavigationSplitView {
            AppSidebarColumn(
                store: store,
                captureConfiguration: captureConfiguration,
                actions: actions
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 225, max: 400)
        } content: {
            SessionListColumn(
                store: store,
                settingsContext: selectedAppContext,
                defaultCaptureInterval: captureConfiguration.defaultCaptureInterval,
                actions: actions
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 275)
        } detail: {
            DetailPaneView(store: store)
                .navigationSplitViewColumnWidth(min: 300, ideal: 500)
        }
        .navigationTitle("Elapse Recorder")
    }

    /// The selected app, resolved from captured apps or synthesized from a whitelist entry
    /// that has no captures yet. Drives the capture-settings inspector in the session column.
    private var selectedApp: AppCaptureSummary? {
        guard let selectedBundleIdentifier = store.selectedBundleIdentifier else {
            return nil
        }

        if let captured = store.apps.first(where: { $0.bundleIdentifier == selectedBundleIdentifier }) {
            return captured
        }

        guard let config = captureConfiguration.whitelistConfigs
            .first(where: { $0.bundleIdentifier == selectedBundleIdentifier })
        else {
            return nil
        }

        return AppCaptureSummary(
            bundleIdentifier: config.bundleIdentifier,
            displayName: config.displayName,
            sessionCount: 0,
            screenshotCount: 0,
            lastCapturedAt: nil
        )
    }

    private var selectedAppContext: CaptureSettingsView.Context? {
        guard let selectedApp else {
            return nil
        }

        return CaptureSettingsView.Context(
            app: selectedApp,
            whitelistConfig: captureConfiguration.whitelistConfigs
                .first { $0.bundleIdentifier == selectedApp.bundleIdentifier },
            isRunning: captureConfiguration.runningApplicationBundleIdentifiers.contains(selectedApp.bundleIdentifier),
            isCapturing: captureConfiguration.activeCaptureBundleIdentifiers.contains(selectedApp.bundleIdentifier)
        )
    }
}

extension ViewerView {
    struct CaptureConfiguration {
        var whitelistConfigs: [WhitelistedAppConfig] = []
        var defaultCaptureInterval: TimeInterval = 5
        var activeCaptureBundleIdentifiers: Set<String> = []
        var runningApplicationBundleIdentifiers: Set<String> = []
        var unavailableReasonsByBundleIdentifier: [String: CaptureUnavailableReason] = [:]
    }

    struct Actions {
        var whitelistApps: ([WhitelistedAppConfig]) -> Void = { _ in }
        var setCaptureState: (AppCaptureSummary, Bool) -> Void = { _, _ in }
        var setCaptureInterval: (AppCaptureSummary, TimeInterval) -> Void = { _, _ in }
        var setCaptureMode: (AppCaptureSummary, CaptureMode) -> Void = { _, _ in }
        var startCapture: (AppCaptureSummary) -> Void = { _ in }
        var stopCapture: (AppCaptureSummary) -> Void = { _ in }
        var removeFromWhitelist: (AppCaptureSummary) -> Void = { _ in }
        var addToWhitelist: (AppCaptureSummary) -> Void = { _ in }
        var deleteAllCaptures: (AppCaptureSummary) -> Void = { _ in }
    }
}

#Preview {
    ViewerView(store: .init(initialState: ViewerFeature.State()) {
        ViewerFeature()
    })
    .frame(width: 1080, height: 720)
}
