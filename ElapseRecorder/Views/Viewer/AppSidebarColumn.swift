import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

/// Sidebar column: whitelisted and stale apps with per-app capture actions, plus the
/// "More Apps…" picker sheet.
struct AppSidebarColumn: View {
    @Bindable var store: StoreOf<ViewerFeature>
    var captureConfiguration: ViewerView.CaptureConfiguration
    var actions: ViewerView.Actions

    @State private var isShowingApplicationSelection = false

    var body: some View {
        List(selection: $store.selectedBundleIdentifier.sending(\.appSelected)) {
            if !whitelistedApps.isEmpty {
                Section("Whitelist") {
                    ForEach(whitelistedApps) { app in
                        appRow(app, whitelistConfig: whitelistConfig(for: app.bundleIdentifier))
                    }
                }
            }

            if !staleApps.isEmpty {
                Section("Stale") {
                    ForEach(staleApps) { app in
                        appRow(app, whitelistConfig: nil)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                isShowingApplicationSelection = true
            } label: {
                Spacer(minLength: 0)

                Label("More Apps…", systemSymbol: .plusApp)
                    .fixedSize()

                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.extraLarge)
            .background(.thinMaterial, in: .buttonBorder)
            .padding()
        }
        .sheet(isPresented: $isShowingApplicationSelection) {
            ApplicationSelectionSheet(
                disabledBundleIdentifiers: whitelistedBundleIdentifiers,
                defaultCaptureInterval: captureConfiguration.defaultCaptureInterval,
                whitelistApplications: actions.whitelistApps
            )
        }
    }

    @ViewBuilder
    private func appRow(
        _ app: AppCaptureSummary,
        whitelistConfig: WhitelistedAppConfig?
    ) -> some View {
        let context = appRowContext(app, whitelistConfig: whitelistConfig)

        AppSidebarRow(
            model: .init(
                app: context.app,
                whitelistConfig: context.whitelistConfig,
                isRunning: context.isRunning,
                isCapturing: context.isCapturing,
                unavailableReason: context.unavailableReason
            ),
            actions: .init(
                setAutoCaptureEnabled: { isEnabled in
                    actions.setCaptureState(context.app, isEnabled)
                },
                startCapture: {
                    actions.startCapture(context.app)
                },
                stopCapture: {
                    actions.stopCapture(context.app)
                }
            )
        )
        .tag(context.app.bundleIdentifier)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                actions.deleteAllCaptures(context.app)
            } label: {
                Label("Delete All Captures", systemSymbol: .trash)
            }

            if let action = captureAction(for: context) {
                Button(action.title, systemSymbol: action.systemSymbol) {
                    perform(action, for: context.app)
                }
                .tint(action.tint)

                Button("Remove \(context.app.displayName) from Whitelist", systemSymbol: .minusCircle) {
                    actions.removeFromWhitelist(context.app)
                }
                .tint(.gray)
            } else {
                Button("Add \(context.app.displayName) to Whitelist", systemSymbol: .plusCircleFill) {
                    actions.addToWhitelist(context.app)
                }
                .tint(.green)
            }
        }
        .contextMenu {
            if let action = captureAction(for: context) {
                Button(action.title, systemSymbol: action.systemSymbol) {
                    perform(action, for: context.app)
                }

                Button("Remove \(context.app.displayName) from Whitelist", systemSymbol: .minusCircle) {
                    actions.removeFromWhitelist(context.app)
                }
            } else {
                Button("Add \(context.app.displayName) to Whitelist", systemSymbol: .plusCircle) {
                    actions.addToWhitelist(context.app)
                }
            }

            Divider()

            Button(role: .destructive) {
                actions.deleteAllCaptures(context.app)
            } label: {
                Label("Delete All Captures", systemSymbol: .trash)
            }
        }
    }

    private func appRowContext(
        _ app: AppCaptureSummary,
        whitelistConfig: WhitelistedAppConfig?
    ) -> AppRowContext {
        AppRowContext(
            app: app,
            whitelistConfig: whitelistConfig,
            isRunning: captureConfiguration.runningApplicationBundleIdentifiers.contains(app.bundleIdentifier),
            isCapturing: captureConfiguration.activeCaptureBundleIdentifiers.contains(app.bundleIdentifier),
            unavailableReason: captureConfiguration.unavailableReasonsByBundleIdentifier[app.bundleIdentifier]
        )
    }

    private func captureAction(for context: AppRowContext) -> AppRowCaptureAction? {
        guard let whitelistConfig = context.whitelistConfig else {
            return nil
        }

        switch whitelistConfig.captureMode {
        case .auto:
            return whitelistConfig.isEnabled ? .pauseAuto : .resumeAuto
        case .manual:
            return context.isCapturing ? .stopCapture : .startCapture
        }
    }

    private func perform(_ action: AppRowCaptureAction, for app: AppCaptureSummary) {
        switch action {
        case .pauseAuto:
            actions.setCaptureState(app, false)
        case .resumeAuto:
            actions.setCaptureState(app, true)
        case .startCapture:
            actions.startCapture(app)
        case .stopCapture:
            actions.stopCapture(app)
        }
    }

    // MARK: Derived app lists

    private var whitelistedApps: [AppCaptureSummary] {
        let capturedAppsByBundleIdentifier = Dictionary(
            store.apps.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        return sortedApps(captureConfiguration.whitelistConfigs.map { config in
            capturedAppsByBundleIdentifier[config.bundleIdentifier]
                ?? AppCaptureSummary(
                    bundleIdentifier: config.bundleIdentifier,
                    displayName: config.displayName,
                    sessionCount: 0,
                    screenshotCount: 0,
                    lastCapturedAt: nil
                )
        })
    }

    private var staleApps: [AppCaptureSummary] {
        sortedApps(
            store.apps.filter { !whitelistedBundleIdentifiers.contains($0.bundleIdentifier) }
        )
    }

    private var whitelistedBundleIdentifiers: Set<String> {
        Set(captureConfiguration.whitelistConfigs.map(\.bundleIdentifier))
    }

    private func whitelistConfig(for bundleIdentifier: String) -> WhitelistedAppConfig? {
        captureConfiguration.whitelistConfigs.first { $0.bundleIdentifier == bundleIdentifier }
    }

    private func sortedApps(_ apps: [AppCaptureSummary]) -> [AppCaptureSummary] {
        apps.sorted { lhs, rhs in
            let lhsName = InstalledAppIdentity(app: lhs).localizedName
            let rhsName = InstalledAppIdentity(app: rhs).localizedName
            let comparison = lhsName.localizedStandardCompare(rhsName)
            if comparison == .orderedSame {
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
            return comparison == .orderedAscending
        }
    }
}

extension AppSidebarColumn {
    private struct AppRowContext {
        var app: AppCaptureSummary
        var whitelistConfig: WhitelistedAppConfig?
        var isRunning: Bool
        var isCapturing: Bool
        var unavailableReason: CaptureUnavailableReason?
    }

    private enum AppRowCaptureAction {
        case pauseAuto
        case resumeAuto
        case startCapture
        case stopCapture

        var title: String {
            switch self {
            case .pauseAuto:
                #tk("Pause Capture")
            case .resumeAuto:
                #tk("Resume Capture")
            case .startCapture:
                #tk("Start Capture")
            case .stopCapture:
                #tk("Stop Capture")
            }
        }

        var systemSymbol: SFSymbol {
            switch self {
            case .pauseAuto:
                .pauseFill
            case .resumeAuto:
                .playFill
            case .startCapture:
                .recordCircle
            case .stopCapture:
                .stopCircle
            }
        }

        var tint: Color {
            switch self {
            case .pauseAuto, .resumeAuto:
                .orange
            case .startCapture, .stopCapture:
                .red
            }
        }
    }
}

#Preview {
    AppSidebarColumn(
        store: Store(
            initialState: {
                var state = ViewerFeature.State()
                state.apps = [
                    AppCaptureSummary(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit", sessionCount: 3, screenshotCount: 128, lastCapturedAt: .now),
                    AppCaptureSummary(bundleIdentifier: "com.apple.Safari", displayName: "Safari", sessionCount: 1, screenshotCount: 20, lastCapturedAt: .now),
                ]
                return state
            }()
        ) {
            ViewerFeature()
        },
        captureConfiguration: ViewerView.CaptureConfiguration(
            whitelistConfigs: [
                WhitelistedAppConfig(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit", captureInterval: 5, isEnabled: true),
            ],
            defaultCaptureInterval: 5,
            activeCaptureBundleIdentifiers: ["com.apple.TextEdit"],
            runningApplicationBundleIdentifiers: ["com.apple.TextEdit"],
            unavailableReasonsByBundleIdentifier: [:]
        ),
        actions: ViewerView.Actions()
    )
    .frame(width: 260, height: 500)
}
