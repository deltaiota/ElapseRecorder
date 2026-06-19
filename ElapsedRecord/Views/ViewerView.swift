import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct ViewerView: View {
    @Bindable var store: StoreOf<ViewerFeature>

    var runningApplications: [RunningApplication] = []
    var whitelistedBundleIdentifiers: Set<String> = []
    var defaultCaptureInterval: TimeInterval = 5
    var refreshAppSelectionSources: () -> Void = {}
    var addAppsToWhitelist: ([WhitelistedAppConfig]) -> Void = { _ in }
    var removeAppFromWhitelist: (AppCaptureSummary) -> Void = { _ in }
    var addAppToWhitelist: (AppCaptureSummary) -> Void = { _ in }
    var deleteApp: (AppCaptureSummary) -> Void = { _ in }

    @State private var isShowingAppSelection = false
    @State private var collapsedSessionDaySections: [SessionDaySection.ID] = []

    var body: some View {
        NavigationSplitView {
            appList()
                .navigationSplitViewColumnWidth(min: 180, ideal: 225, max: 400)
                .sheet(isPresented: $isShowingAppSelection) {
                    AppSelectionSheet(
                        runningApplications: runningApplications,
                        detectedApps: store.apps,
                        whitelistedBundleIdentifiers: whitelistedBundleIdentifiers,
                        defaultCaptureInterval: defaultCaptureInterval,
                        addAppsToWhitelist: addAppsToWhitelist
                    )
                }
        } content: {
            sessionList()
                .navigationSplitViewColumnWidth(min: 200, ideal: 275)
        } detail: {
            detailPane()
                .navigationSplitViewColumnWidth(min: 300, ideal: 500)
        }
        .navigationTitle("Elapsed Record")
        .sheet(item: $store.selectedScreenshot.sending(\.screenshotSelected)) { record in
            ScreenshotDetailView(
                record: record,
                revealInFinder: {
                    store.send(.revealSelectedScreenshotInFinderButtonTapped)
                }
            )
        }
    }

    private func appList() -> some View {
        List(selection: $store.selectedBundleIdentifier.sending(\.appSelected)) {
            if !whitelistedApps.isEmpty {
                Section("Whitelisted") {
                    ForEach(whitelistedApps) { app in
                        appRow(app, isWhitelisted: true)
                    }
                }
            }

            if !removedApps.isEmpty {
                Section("Removed from Whitelist") {
                    ForEach(removedApps) { app in
                        appRow(app, isWhitelisted: false)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                refreshAppSelectionSources()
                isShowingAppSelection = true
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
    }

    private func appRow(
        _ app: AppCaptureSummary,
        isWhitelisted: Bool
    ) -> some View {
        AppSidebarRow(app: app, isWhitelisted: isWhitelisted)
            .tag(app.bundleIdentifier)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteApp(app)
                } label: {
                    Label("Delete All Captures", systemSymbol: .trash)
                }

                if isWhitelisted {
                    Button("Remove from Whitelist", systemSymbol: .pauseFill) {
                        removeAppFromWhitelist(app)
                    }
                    .tint(.orange)
                } else {
                    Button("Add to Whitelist", systemSymbol: .playFill) {
                        addAppToWhitelist(app)
                    }
                    .tint(.green)
                }
            }
            .contextMenu {
                if isWhitelisted {
                    Button("Remove from Whitelist", systemSymbol: .pause) {
                        removeAppFromWhitelist(app)
                    }
                } else {
                    Button("Add to Whitelist", systemSymbol: .play) {
                        addAppToWhitelist(app)
                    }
                }

                Divider()

                Button(role: .destructive) {
                    deleteApp(app)
                } label: {
                    Label("Delete All Captures", systemSymbol: .trash)
                }
            }
    }

    private func sessionList() -> some View {
        List(selection: $store.sessionListSelection.sending(\.sessionListSelectionChanged)) {
            if store.selectedBundleIdentifier != nil {
                if let errorMessage = store.errorMessage {
                    Label(errorMessage, systemSymbol: .exclamationmarkTriangle)
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                Label("All Screenshots", systemSymbol: .photoStack)
                    .tag(ViewerFeature.State.SessionListSelection.flat)
                    .listRowSeparator(.hidden)

                ForEach(sessionDaySections) { section in
                    Section(isExpanded: $collapsedSessionDaySections[contains: section.id].negate()) {
                        ForEach(section.sessions) { session in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(session.startedAt, format: .dateTime.hour().minute())
                                    CountSummary(
                                        items: [
                                            .init(text: sessionDuration(session), systemSymbol: .timer, isMonospaced: true),
                                            .init(value: session.windowCount, systemSymbol: .macwindow),
                                            .init(value: session.screenshotCount, systemSymbol: .photo),
                                        ]
                                    )
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                }
                            } icon: {
                                Image(systemSymbol: .clock)
                            }
                            .tag(ViewerFeature.State.SessionListSelection.session(id: session.id))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.send(.deleteSessionButtonTapped(session))
                                } label: {
                                    Label(TK.Action.delete, systemSymbol: .trash)
                                }
                                .tint(.red)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.send(.deleteSessionButtonTapped(session))
                                } label: {
                                    Label("Delete Session", systemSymbol: .trash)
                                }
                            }
                        }
                    } header: {
                        Text(section.day, format: .dateTime.year().month().day())
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .center) {
            if store.selectedBundleIdentifier == nil {
                ContentUnavailableView(
                    "Choose an app",
                    systemSymbol: .app,
                    description: Text("Captured sessions will appear here.")
                )
            }
        }
        .background(.windowBackground)
    }

    private func detailPane() -> some View {
        Group {
            if store.isShowingFlatGallery {
                ScreenshotGrid(
                    records: store.flatScreenshots,
                    selectScreenshot: { store.send(.screenshotSelected($0)) }
                )
                .navigationTitle("All screenshots")
            } else if store.selectedSessionID != nil {
                ScreenshotGrid(
                    records: store.windowScreenshots,
                    selectScreenshot: { store.send(.screenshotSelected($0)) }
                )
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 0) {
                        Picker("Window", selection: $store.windowPickerSelection.sending(\.windowPickerSelectionChanged)) {
                            Text("All Windows")
                                .tag(ViewerFeature.State.WindowPickerSelection.all)

                            if !store.windows.isEmpty {
                                Divider()

                                ForEach(store.windows) { window in
                                    Button {} label: {
                                        Text(windowTitle(window))

                                        CountSummary(
                                            items: [
                                                .init(value: window.screenshotCount, systemSymbol: .photo),
                                            ]
                                        )
                                    }
                                    .tag(ViewerFeature.State.WindowPickerSelection.window(id: window.id))
                                }
                            }
                        }
                        .padding()
                        .background(.bar)

                        Divider()
                    }
                }
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .center) {
            if !store.isShowingFlatGallery && store.selectedSessionID == nil {
                ContentUnavailableView(
                    "Choose a session",
                    systemSymbol: .clock,
                    description: Text("Windows and screenshots will appear here.")
                )
            }
        }
        .background(.background)
    }

    private var sessionDaySections: [SessionDaySection] {
        let calendar = Calendar.current
        let groupedSessions = Dictionary(grouping: store.sessions) { session in
            calendar.startOfDay(for: session.startedAt)
        }

        return groupedSessions.keys
            .sorted(by: >)
            .map { day in
                SessionDaySection(
                    day: day,
                    sessions: (groupedSessions[day] ?? []).sorted { $0.startedAt > $1.startedAt }
                )
            }
    }

    private var whitelistedApps: [AppCaptureSummary] {
        sortedApps(
            store.apps.filter { whitelistedBundleIdentifiers.contains($0.bundleIdentifier) }
        )
    }

    private var removedApps: [AppCaptureSummary] {
        sortedApps(
            store.apps.filter { !whitelistedBundleIdentifiers.contains($0.bundleIdentifier) }
        )
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

    private func sessionDuration(_ session: CaptureSessionSummary) -> String {
        Duration.seconds(session.duration)
            .formatted(.time(pattern: .hourMinuteSecond))
    }

    private func windowTitle(_ window: WindowCaptureSummary) -> String {
        if let label = window.label, !label.isEmpty {
            return #tk("Window \(window.displayNumber): \(label)")
        }
        return #tk("Window \(window.displayNumber)")
    }
}

#Preview {
    ViewerView(store: .init(initialState: ViewerFeature.State()) {
        ViewerFeature()
    })
    .frame(width: 1080, height: 720)
}
