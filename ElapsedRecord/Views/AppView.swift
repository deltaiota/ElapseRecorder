import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        VStack(spacing: 0) {
            whitelistBar()
                .padding()
                .background(.regularMaterial)

            Divider()

            ViewerView(
                store: store.scope(
                    state: \.viewer,
                    action: \.viewer
                )
            )
        }
        .task {
            await store.send(.task).finish()
        }
    }

//    var body: some View {
//        ViewerView(store: store.scope(
//            state: \.viewer,
//            action: \.viewer
//        ))
//    }

    private func whitelistBar() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Label(#tk("Whitelist"), systemSymbol: .app)
                    .font(.headline)

                activeCaptureStatus()

                captureStatus()

                Spacer()

                Button {
                    store.send(.revealCaptureRootButtonTapped)
                } label: {
                    Label(#tk("Reveal captures"), systemSymbol: .folder)
                }

                runningApplicationsMenu()

                Button {
                    store.send(.refreshRunningApplicationsButtonTapped)
                } label: {
                    Label(#tk("Refresh apps"), systemSymbol: .arrowClockwise)
                }

                Button {
                    store.send(.refreshViewerButtonTapped)
                } label: {
                    Label(#tk("Refresh viewer"), systemSymbol: .arrowClockwise)
                }

                diagnosticsMenu()
            }

            lifecycleDiagnostics()

            HStack(alignment: .center, spacing: 8) {
                TextField(
                    #tk("Bundle ID"),
                    text: $store.draftBundleIdentifier.sending(\.draftBundleIdentifierChanged)
                )
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)

                TextField(
                    #tk("Display name"),
                    text: $store.draftDisplayName.sending(\.draftDisplayNameChanged)
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

                Stepper(
                    value: $store.draftIntervalSeconds.sending(\.draftIntervalSecondsChanged),
                    in: 1 ... 3600,
                    step: 1
                ) {
                    Text(#tk("Every \(Int(store.draftIntervalSeconds))s"))
                        .monospacedDigit()
                }
                .frame(width: 130)

                Button {
                    store.send(.addDraftWhitelistButtonTapped)
                } label: {
                    Label(#tk("Add"), systemSymbol: .plusCircle)
                }
                .disabled(!store.canAddDraftWhitelist)

                if let whitelistError = store.whitelistError {
                    Label(whitelistError, systemSymbol: .exclamationmarkTriangle)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                if let captureRootError = store.captureRootError {
                    Label(captureRootError, systemSymbol: .exclamationmarkTriangle)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

//            if store.whitelistConfigs.isEmpty {
//                Text(#tk("Add an app to the whitelist. If it is already running, recording starts immediately; otherwise it starts on launch."))
//                    .font(.caption)
//                    .foregroundStyle(.secondary)
//            } else {
//                ScrollView(.horizontal) {
//                    HStack(alignment: .top, spacing: 10) {
//                        ForEach(store.sortedWhitelistConfigs) { config in
//                            whitelistConfigCard(config)
//                        }
//                    }
//                }
//                .scrollIndicators(.hidden)
//            }
        }
    }

    private func runningApplicationsMenu() -> some View {
        Menu {
            if store.runningApplicationsAvailableForWhitelist.isEmpty {
                Text(#tk("No running apps to add"))
            } else {
                ForEach(store.runningApplicationsAvailableForWhitelist) { application in
                    Button {
                        store.send(.addRunningApplicationButtonTapped(application.bundleIdentifier))
                    } label: {
                        Text("\(application.displayName) (\(application.bundleIdentifier))")
                    }
                }
            }
        } label: {
            Label(#tk("Add running app"), systemSymbol: .plusCircle)
        }
    }

    @ViewBuilder private func diagnosticsMenu() -> some View {
        if !store.captureEngine.recentDiagnostics.isEmpty {
            Menu {
                ForEach(Array(store.captureEngine.recentDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Text(diagnostic)
                }
            } label: {
                Label(#tk("Diagnostics"), systemSymbol: .stethoscope)
            }
        }
    }

//    @ViewBuilder private func whitelistConfigCard(_ config: WhitelistedAppConfig) -> some View {
//        VStack(alignment: .leading, spacing: 8) {
//            HStack {
//                Toggle(
//                    isOn: Binding(
//                        get: { config.isEnabled },
//                        set: { store.send(.whitelistEnabledChanged(config.bundleIdentifier, $0)) }
//                    )
//                ) {
//                    Text(config.displayName)
//                        .font(.headline)
//                        .lineLimit(1)
//                }
//
//                Button {
//                    store.send(.removeWhitelistButtonTapped(config.bundleIdentifier))
//                } label: {
//                    Image(systemSymbol: .trash)
//                }
//                .buttonStyle(.borderless)
//            }
//
//            Text(config.bundleIdentifier)
//                .font(.caption)
//                .foregroundStyle(.secondary)
//                .lineLimit(1)
//
//            Stepper(
//                value: Binding(
//                    get: { config.captureInterval },
//                    set: { store.send(.whitelistIntervalChanged(config.bundleIdentifier, $0)) }
//                ),
//                in: 1 ... 3600,
//                step: 1
//            ) {
//                Text(#tk("Every \(Int(config.captureInterval))s"))
//                    .monospacedDigit()
//            }
//
//            whitelistStatus(config)
//
//            whitelistRuntimeDetails(config)
//        }
//        .padding(10)
//        .frame(width: 260, alignment: .leading)
//        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
//    }

    @ViewBuilder private func whitelistStatus(_ config: WhitelistedAppConfig) -> some View {
        if store.captureEngine.activeSessions[config.bundleIdentifier] != nil {
            Label(#tk("Capturing"), systemSymbol: .recordCircle)
                .foregroundStyle(.green)
        } else if !config.isEnabled {
            Label(#tk("Disabled"), systemSymbol: .pauseCircle)
                .foregroundStyle(.secondary)
        } else if store.captureEngine.runningApplications[config.bundleIdentifier] != nil {
            Label(#tk("Running, waiting to start"), systemSymbol: .clock)
                .foregroundStyle(.orange)
        } else {
            Label(#tk("Starts on launch"), systemSymbol: .clock)
                .foregroundStyle(.secondary)
        }
    }

    private func lifecycleDiagnostics() -> some View {
        HStack(spacing: 12) {
            Label(#tk("\(store.captureEngine.runningApplications.count) running apps seen"), systemSymbol: .app)
                .foregroundStyle(.secondary)

            if let event = store.captureEngine.lastWorkspaceEvent {
                Label(workspaceEventSummary(event), systemSymbol: .clock)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label(#tk("No workspace event yet"), systemSymbol: .clock)
                    .foregroundStyle(.secondary)
            }

            if let lastError = store.captureEngine.lastError {
                Label(lastError, systemSymbol: .exclamationmarkTriangle)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .font(.caption)
    }

    @ViewBuilder private func whitelistRuntimeDetails(_ config: WhitelistedAppConfig) -> some View {
        if let active = store.captureEngine.activeSessions[config.bundleIdentifier] {
            Text(#tk("Session \(active.session.id.uuidString.prefix(8)) - PID \(active.application.processIdentifier)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let application = store.captureEngine.runningApplications[config.bundleIdentifier] {
            Text(#tk("Matched running app - PID \(application.processIdentifier)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(#tk("No running process matched"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func activeCaptureStatus() -> some View {
        let activeSessions = store.captureEngine.activeSessions.values.sorted {
            $0.config.displayName < $1.config.displayName
        }

        if activeSessions.isEmpty {
            Label(#tk("Idle"), systemSymbol: .pauseCircle)
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(activeSessions, id: \.session.id) { active in
                    Text(#tk("\(active.config.displayName) every \(Int(active.config.captureInterval))s"))
                }
            } label: {
                Label(#tk("Capturing \(activeSessions.count)"), systemSymbol: .recordCircle)
            }
            .foregroundStyle(.green)
        }
    }

    @ViewBuilder private func captureStatus() -> some View {
        switch store.captureEngine.permissionStatus {
        case .authorized:
            Label(#tk("Ready"), systemSymbol: .checkmarkCircle)
                .foregroundStyle(.secondary)

        case .notDetermined:
            Button {
                store.send(.requestCapturePermissionButtonTapped)
            } label: {
                Label(#tk("Request Screen Recording"), systemSymbol: .questionmarkCircle)
            }

        case .denied:
            HStack(spacing: 6) {
                Label(#tk("Screen Recording denied"), systemSymbol: .exclamationmarkTriangle)
                    .foregroundStyle(.orange)

                Button {
                    store.send(.requestCapturePermissionButtonTapped)
                } label: {
                    Text(#tk("Retry"))
                }
            }
        }
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
}

#Preview {
    AppView(store: .init(initialState: AppFeature.State()) {
        AppFeature()
    })
    .frame(width: 1080, height: 720)
}
