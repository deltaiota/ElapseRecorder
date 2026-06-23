import ComposableArchitecture
import Foundation
import IssueReporting
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var isShowingDiagnosticsPopover = false
    @State private var isShowingRecordingPermissionHint = false
    @State private var refreshButtonAnimationTrigger: Int = 0

    var body: some View {
        ViewerView(
            store: store.scope(
                state: \.viewer,
                action: \.viewer
            ),
            captureConfiguration: viewerCaptureConfiguration,
            actions: viewerActions
        )
        .navigationSubtitle(captureCountSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                screenRecordingStatus()
            }

            ToolbarItemGroup(placement: .primaryAction) {
                diagnosticsPopoverButton()
                refreshButton()
                revealCapturesButton()
            }
        }
        .task {
            guard !isTesting else {
                return
            }

            await store.send(.task).finish()
        }
        .onAppear {
            updateRecordingPermissionHint(for: store.captureEngine.permissionStatus)
        }
        .onChange(of: store.captureEngine.permissionStatus) { _, permissionStatus in
            updateRecordingPermissionHint(for: permissionStatus)
        }
    }

    @ViewBuilder
    private func screenRecordingStatus() -> some View {
        Button {
            store.send(.requestCapturePermissionButtonTapped)
        } label: {
            HStack(spacing: -8) {
                Image(systemSymbol: .recordCircle)
                    .foregroundStyle(.red)
                    .zIndex(-1)

                Group {
                    switch store.captureEngine.permissionStatus {
                    case .authorized:
                        Label("Screen Recording Ready", systemSymbol: .checkmarkSealFill)
                            .foregroundStyle(.green)

                    case .notDetermined:
                        Label("Request Screen Recording Permission", systemSymbol: .questionmarkCircleFill)
                            .foregroundStyle(.yellow)

                    case .denied:
                        Label("Request Screen Recording Permission", systemSymbol: .exclamationmarkTriangleFill)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .background(.selection.secondary, in: .buttonBorder)
        .popover(isPresented: $isShowingRecordingPermissionHint, arrowEdge: .bottom) {
            recordingPermissionHint()
        }
        .disabled(store.captureEngine.permissionStatus == .authorized)
    }

    @ViewBuilder
    private func recordingPermissionHint() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Screen Recording Permission Required")
            } icon: {
                Image(systemSymbol: .recordCircle)
                    .foregroundStyle(.red)
            }
            .font(.headline)

            Text("Screen Recording permission needs to be granted before capturing app windows.")
                .foregroundStyle(.secondary)

            if store.captureEngine.permissionStatus == .denied {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("If granting permission failed, open System Settings > Privacy & Security > Screen & System Audio Recording (click to open), remove Elapse Recorder and add it back, then reopen the app.")
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                store.send(.requestCapturePermissionButtonTapped)
            } label: {
                Label("Grant Permission", systemSymbol: .checkmarkSealFill)
            }
            .controlSize(.large)
        }
        .padding(12)
        .frame(width: Self.recordingPermissionHintWidth, alignment: .leading)
    }

    @ViewBuilder
    private func diagnosticsPopoverButton() -> some View {
        Button {
            isShowingDiagnosticsPopover.toggle()
        } label: {
            Label(diagnosticsButtonTitle, systemSymbol: .stethoscope)
        }
        .popover(isPresented: $isShowingDiagnosticsPopover, arrowEdge: .bottom) {
            diagnosticsPopover()
        }
    }

    @ViewBuilder
    private func diagnosticsPopover() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Diagnostics", systemSymbol: .stethoscope)
                    .font(.headline)

                diagnosticsSection("Capture") {
                    diagnosticsRow("Permission", permissionStatusText, systemSymbol: .checkmarkSeal)
                    diagnosticsRow("Active sessions", activeCaptureSessions.count.formatted(), systemSymbol: .recordCircle)
                    diagnosticsRow("Whitelist", store.whitelistConfigs.count.formatted(), systemSymbol: .listClipboard)
                    diagnosticsRow("Running apps seen", store.captureEngine.runningApplications.count.formatted(), systemSymbol: .appBadgeClock)
                }

                if !activeCaptureSessions.isEmpty {
                    diagnosticsSection("Active Sessions") {
                        ForEach(activeCaptureSessions, id: \.session.id) { active in
                            diagnosticsRow(
                                active.config.displayName,
                                activeSessionSummary(active),
                                systemSymbol: active.isCaptureInFlight ? .recordCircle : .clock
                            )
                        }
                    }
                }

                diagnosticsSection("Workspace") {
                    if let event = store.captureEngine.lastWorkspaceEvent {
                        diagnosticsRow("Last event", workspaceEventSummary(event), systemSymbol: .clock)
                    } else {
                        diagnosticsRow("Last event", "None", systemSymbol: .clock)
                    }
                }

                if hasAppErrors {
                    diagnosticsSection("Errors") {
                        if let whitelistError = store.whitelistError {
                            diagnosticsRow("Whitelist", whitelistError, systemSymbol: .exclamationmarkTriangle)
                        }

                        if let captureRootError = store.captureRootError {
                            diagnosticsRow("Capture folder", captureRootError, systemSymbol: .exclamationmarkTriangle)
                        }

                        if let lastError = store.captureEngine.lastError {
                            diagnosticsRow("Capture engine", lastError, systemSymbol: .exclamationmarkTriangle)
                        }
                    }
                }

                diagnosticsSection("Recent Diagnostics") {
                    recentDiagnostics()
                }
            }
            .frame(width: Self.diagnosticsPopoverContentWidth, alignment: .leading)
            .padding(Self.diagnosticsPopoverPadding)
        }
        .frame(width: Self.diagnosticsPopoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: Self.diagnosticsPopoverMaximumHeight)
    }

    @ViewBuilder
    private func diagnosticsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .bold()
                .foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                content()
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func diagnosticsRow(
        _ title: String,
        _ value: String,
        systemSymbol: SFSymbol
    ) -> some View {
        GridRow {
            Image(systemSymbol: systemSymbol)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func recentDiagnostics() -> some View {
        if store.captureEngine.recentDiagnostics.isEmpty {
            Text("No recent diagnostics")
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(store.captureEngine.recentDiagnostics.reversed().enumerated()), id: \.offset) { _, diagnostic in
                Text(diagnostic)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func refreshButton() -> some View {
        Button("Refresh", systemSymbol: .arrowCounterclockwise) {
            store.send(.refreshViewerButtonTapped)
            store.send(.refreshRunningApplicationsButtonTapped)
            refreshButtonAnimationTrigger += 1
        }
        .symbolEffect(.rotate, options: .speed(8), value: refreshButtonAnimationTrigger)
    }

    @ViewBuilder
    private func revealCapturesButton() -> some View {
        Button {
            store.send(.revealCaptureRootButtonTapped)
        } label: {
            Label("Reveal Captures", systemSymbol: .folder)
        }
    }

    private var activeCaptureSessions: [CaptureEngineFeature.State.ActiveSession] {
        store.captureEngine.activeSessions.values.sorted {
            $0.config.displayName < $1.config.displayName
        }
    }

    private var viewerCaptureConfiguration: ViewerView.CaptureConfiguration {
        ViewerView.CaptureConfiguration(
            whitelistConfigs: store.whitelistConfigs,
            defaultCaptureInterval: store.draftIntervalSeconds,
            activeCaptureBundleIdentifiers: Set(store.captureEngine.activeSessions.keys),
            runningApplicationBundleIdentifiers: Set(store.captureEngine.runningApplications.keys),
            unavailableReasonsByBundleIdentifier: store.captureEngine.activeSessions.compactMapValues(\.captureUnavailableReason)
        )
    }

    private var viewerActions: ViewerView.Actions {
        ViewerView.Actions(
            whitelistApps: { configs in
                store.send(.addWhitelistConfigsButtonTapped(configs))
            },
            setCaptureState: { app, isEnabled in
                store.send(.whitelistEnabledChanged(app.bundleIdentifier, isEnabled))
            },
            setCaptureInterval: { app, interval in
                store.send(.whitelistIntervalChanged(app.bundleIdentifier, interval))
            },
            setCaptureMode: { app, captureMode in
                store.send(.whitelistCaptureModeChanged(app.bundleIdentifier, captureMode))
            },
            startCapture: { app in
                store.send(.captureEngine(.captureStart(app.bundleIdentifier)))
            },
            stopCapture: { app in
                store.send(.captureEngine(.captureStop(app.bundleIdentifier)))
            },
            removeFromWhitelist: { app in
                store.send(.removeViewerAppFromWhitelistButtonTapped(app))
            },
            addToWhitelist: { app in
                store.send(.addViewerAppToWhitelistButtonTapped(app))
            },
            deleteAllCaptures: { app in
                store.send(.deleteViewerAppButtonTapped(app))
            }
        )
    }

    private var diagnosticsButtonTitle: String {
        store.captureEngine.recentDiagnostics.isEmpty
            ? #tk("Diagnostics")
            : #tk("Diagnostics \(store.captureEngine.recentDiagnostics.count)")
    }

    private var captureCountSubtitle: String {
        #tk("Capturing \(activeCaptureSessions.count) Apps")
    }

    private var permissionStatusText: String {
        switch store.captureEngine.permissionStatus {
        case .authorized:
            #tk("Authorized")
        case .notDetermined:
            #tk("Not determined")
        case .denied:
            #tk("Denied")
        }
    }

    private var hasAppErrors: Bool {
        store.whitelistError != nil
            || store.captureRootError != nil
            || store.captureEngine.lastError != nil
    }

    private func activeSessionSummary(_ active: CaptureEngineFeature.State.ActiveSession) -> String {
        let sessionID = active.session.id.uuidString.prefix(8)
        let flightState = active.isCaptureInFlight ? #tk("capturing") : #tk("waiting")
        return #tk("PID \(active.application.processIdentifier), session \(sessionID), every \(Int(active.config.captureInterval))s, \(flightState)")
    }

    private func workspaceEventSummary(_ event: WorkspaceEvent) -> String {
        switch event {
        case let .launched(application):
            #tk("Last event: launched \(application.displayName)")
        case let .terminated(application):
            #tk("Last event: quit \(application.displayName)")
        case let .activated(application):
            #tk("Last event: activated \(application.displayName)")
        }
    }

    private func updateRecordingPermissionHint(for permissionStatus: CapturePermissionStatus) {
        isShowingRecordingPermissionHint = permissionStatus != .authorized
    }

    private static let diagnosticsPopoverWidth: CGFloat = 340
    private static let diagnosticsPopoverMaximumHeight: CGFloat = 520
    private static let diagnosticsPopoverPadding: CGFloat = 10
    private static let diagnosticsPopoverContentWidth = diagnosticsPopoverWidth - diagnosticsPopoverPadding * 2
    private static let recordingPermissionHintWidth: CGFloat = 300
}

#Preview {
    AppView(store: .init(initialState: AppFeature.State()) {
        AppFeature()
    })
    .frame(width: 1080, height: 720)
}
