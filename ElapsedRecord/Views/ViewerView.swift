import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct ViewerView: View {
    @Bindable var store: StoreOf<ViewerFeature>

    var whitelistConfigs: [WhitelistedAppConfig] = []
    var defaultCaptureInterval: TimeInterval = 5
    var whitelistApps: ([WhitelistedAppConfig]) -> Void = { _ in }
    var setCaptureState: (AppCaptureSummary, Bool) -> Void = { _, _ in }
    var setCaptureInterval: (AppCaptureSummary, TimeInterval) -> Void = { _, _ in }
    var setCaptureMode: (AppCaptureSummary, CaptureMode) -> Void = { _, _ in }
    var startManualCapture: (AppCaptureSummary) -> Void = { _ in }
    var stopManualCapture: (AppCaptureSummary) -> Void = { _ in }
    var activeCaptureBundleIdentifiers: Set<String> = []
    var runningApplicationBundleIdentifiers: Set<String> = []
    var removeFromWhitelist: (AppCaptureSummary) -> Void = { _ in }
    var addToWhitelist: (AppCaptureSummary) -> Void = { _ in }
    var deleteAllCaptures: (AppCaptureSummary) -> Void = { _ in }

    @State private var isShowingApplicationSelection = false
    @State private var collapsedSessionDaySections: [SessionDaySection.ID] = []

    var body: some View {
        NavigationSplitView {
            appList()
                .navigationSplitViewColumnWidth(min: 180, ideal: 225, max: 400)
                .sheet(isPresented: $isShowingApplicationSelection) {
                    ApplicationSelectionSheet(
                        disabledBundleIdentifiers: whitelistedBundleIdentifiers,
                        defaultCaptureInterval: defaultCaptureInterval,
                        whitelistApplications: whitelistApps
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

    @ViewBuilder
    private func appList() -> some View {
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
                isManualCapturing: context.isManualCapturing
            ),
            actions: .init(
                setAutoCaptureEnabled: { isEnabled in
                    setCaptureState(context.app, isEnabled)
                },
                startManualCapture: {
                    startManualCapture(context.app)
                },
                stopManualCapture: {
                    stopManualCapture(context.app)
                }
            )
        )
        .tag(context.app.bundleIdentifier)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteAllCaptures(context.app)
            } label: {
                Label("Delete All Captures", systemSymbol: .trash)
            }

            if let action = captureAction(for: context) {
                Button(action.title, systemSymbol: action.systemSymbol) {
                    perform(action, for: context.app)
                }
                .tint(action.tint)

                Button("Remove \(context.app.displayName) from Whitelist", systemSymbol: .minusCircle) {
                    removeFromWhitelist(context.app)
                }
                .tint(.gray)
            } else {
                Button("Add \(context.app.displayName) to Whitelist", systemSymbol: .plusCircleFill) {
                    addToWhitelist(context.app)
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
                    removeFromWhitelist(context.app)
                }
            } else {
                Button("Add \(context.app.displayName) to Whitelist", systemSymbol: .plusCircle) {
                    addToWhitelist(context.app)
                }
            }

            Divider()

            Button(role: .destructive) {
                deleteAllCaptures(context.app)
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
            isRunning: runningApplicationBundleIdentifiers.contains(app.bundleIdentifier),
            isManualCapturing: activeCaptureBundleIdentifiers.contains(app.bundleIdentifier)
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
            return context.isManualCapturing ? .stopManual : .startManual
        }
    }

    private func perform(_ action: AppRowCaptureAction, for app: AppCaptureSummary) {
        switch action {
        case .pauseAuto:
            setCaptureState(app, false)
        case .resumeAuto:
            setCaptureState(app, true)
        case .startManual:
            startManualCapture(app)
        case .stopManual:
            stopManualCapture(app)
        }
    }

    @ViewBuilder
    private func sessionList() -> some View {
        List(selection: $store.sessionListSelection.sending(\.sessionListSelectionChanged)) {
            if selectedApp != nil {
                if let errorMessage = store.errorMessage {
                    Label(errorMessage, systemSymbol: .exclamationmarkTriangle)
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help(errorMessage)
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
                                            .init(text: sessionDuration(session), systemSymbol: .clock, isMonospaced: true),
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
        .safeAreaInset(edge: .bottom) {
            if selectedApp != nil {
                VStack(spacing: 0) {
                    Divider()

                    captureSettings()
                        .padding()
                }
                .background(.windowBackground)
            }
        }
        .overlay(alignment: .center) {
            if selectedApp == nil {
                ContentUnavailableView(
                    "Choose an App",
                    systemSymbol: .appDashed,
                    description: Text("Captured sessions will appear here.")
                )
            }
        }
        .background(.windowBackground)
    }

    @ViewBuilder
    private func detailPane() -> some View {
        Group {
            if store.isShowingFlatGallery {
                ScreenshotGrid(
                    records: store.flatScreenshots,
                    selectScreenshot: { store.send(.screenshotSelected($0)) }
                )
                .navigationTitle("All Screenshots")
            } else if store.selectedSessionID != nil {
                ScreenshotGrid(
                    records: store.windowScreenshots,
                    selectScreenshot: { store.send(.screenshotSelected($0)) }
                )
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        Divider()

                        HStack {
                            Picker("Window", selection: $store.windowPickerSelection.sending(\.windowPickerSelectionChanged)) {
                                Text("All Windows")
                                    .tag(ViewerFeature.State.WindowPickerSelection.all)

                                if !store.windows.isEmpty {
                                    Divider()

                                    ForEach(store.windows) { window in
                                        Button {} label: {
                                            Text(windowTitle(window))

                                            Text("\(window.screenshotCount) Screenshots")
                                        }
                                        .tag(ViewerFeature.State.WindowPickerSelection.window(id: window.id))
                                    }
                                }
                            }
                            .labelsHidden()
                            .buttonStyle(.borderless)

                            Spacer()

                            Button("Export…") {}
                        }
                        .padding()
                    }
                    .background(.bar)
                }
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .center) {
            if !store.isShowingFlatGallery && store.selectedSessionID == nil {
                ContentUnavailableView(
                    "Choose a Session",
                    systemSymbol: .film,
                    description: Text("Windows and screenshots will appear here.")
                )
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private func captureSettings() -> some View {
        if let context = selectedAppContext {
            HStack {
                if context.isWhitelisted {
                    VStack(spacing: 12) {
                        captureIntervalSettings(for: context)
                        captureModeSettings(for: context)
                    }
                } else {
                    Label("Whitelist this app to configure capture.", systemSymbol: .minusCircle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func captureIntervalSettings(for context: SelectedAppContext) -> some View {
        VStack(alignment: .leading) {
            Label("Capture Interval", systemSymbol: .timer)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Stepper(
                    value: captureIntervalSecondsBinding(for: context.app),
                    in: Self.captureIntervalSecondsRange,
                    step: 1
                ) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Every")

                        TextField(
                            "Seconds",
                            value: captureIntervalSecondsBinding(for: context.app),
                            format: .number
                        )
                        .monospaced()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                        .textFieldStyle(.plain)

                        Text("s")
                    }
                }
                .controlSize(.small)
                .fixedSize()

                Spacer(minLength: 12)

                Slider(
                    value: captureIntervalPresetBinding(for: context.app),
                    in: Self.captureIntervalPresetIndexRange,
                    step: 1
                ) {
                    Text("Capture Interval")
                } minimumValueLabel: {
                    Text("1s")
                } maximumValueLabel: {
                    Text("1h")
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func captureModeSettings(for context: SelectedAppContext) -> some View {
        VStack(alignment: .leading) {
            Label("Capture Mode", systemSymbol: .camera)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Capture Mode", selection: captureModeBinding(for: context.app)) {
                    Text("Auto")
                        .tag(CaptureMode.auto)

                    Text("Manual")
                        .tag(CaptureMode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 12)

                captureModeControl(for: context)
            }
        }
    }

    @ViewBuilder
    private func captureModeControl(for context: SelectedAppContext) -> some View {
        switch context.whitelistConfig?.captureMode {
        case .auto:
            if context.whitelistConfig?.isEnabled == true {
                Button {
                    setCaptureState(context.app, false)
                } label: {
                    Text("Pause")

                    Image(systemSymbol: .pauseFill)
                }
            } else {
                Button {
                    setCaptureState(context.app, true)
                } label: {
                    Text("Resume")

                    Image(systemSymbol: .playFill)
                }
            }

        case .manual:
            Group {
                if context.isCapturing {
                    Button {
                        stopManualCapture(context.app)
                    } label: {
                        Text("Stop")

                        Image(systemSymbol: .stopCircle)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        startManualCapture(context.app)
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
        let capturedAppsByBundleIdentifier = Dictionary(
            store.apps.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        return sortedApps(whitelistConfigs.map { config in
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

    private var selectedApp: AppCaptureSummary? {
        guard let selectedBundleIdentifier = store.selectedBundleIdentifier else {
            return nil
        }

        return (whitelistedApps + staleApps).first { $0.bundleIdentifier == selectedBundleIdentifier }
    }

    private var selectedAppContext: SelectedAppContext? {
        guard let selectedApp else {
            return nil
        }

        return SelectedAppContext(
            app: selectedApp,
            whitelistConfig: whitelistConfig(for: selectedApp.bundleIdentifier),
            isRunning: runningApplicationBundleIdentifiers.contains(selectedApp.bundleIdentifier),
            isCapturing: activeCaptureBundleIdentifiers.contains(selectedApp.bundleIdentifier)
        )
    }

    private var whitelistedBundleIdentifiers: Set<String> {
        Set(whitelistConfigs.map(\.bundleIdentifier))
    }

    private func whitelistConfig(for bundleIdentifier: String) -> WhitelistedAppConfig? {
        whitelistConfigs.first { $0.bundleIdentifier == bundleIdentifier }
    }

    private func captureInterval(for app: AppCaptureSummary) -> TimeInterval {
        whitelistConfig(for: app.bundleIdentifier)?.captureInterval ?? defaultCaptureInterval
    }

    private func captureIntervalSecondsBinding(for app: AppCaptureSummary) -> Binding<Int> {
        Binding(
            get: {
                Int(captureInterval(for: app))
            },
            set: {
                setCaptureInterval(app, TimeInterval($0))
            }
        )
    }

    private func captureModeBinding(for app: AppCaptureSummary) -> Binding<CaptureMode> {
        Binding(
            get: {
                whitelistConfig(for: app.bundleIdentifier)?.captureMode ?? .auto
            },
            set: {
                setCaptureMode(app, $0)
            }
        )
    }

    private func captureIntervalPresetBinding(for app: AppCaptureSummary) -> Binding<Double> {
        Binding(
            get: {
                Double(nearestCaptureIntervalPresetIndex(for: captureInterval(for: app)))
            },
            set: { index in
                let clampedIndex = min(
                    max(Int(index.rounded()), 0),
                    Self.captureIntervalPresetSeconds.count - 1
                )
                setCaptureInterval(app, Self.captureIntervalPresetSeconds[clampedIndex])
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

    private struct AppRowContext {
        var app: AppCaptureSummary
        var whitelistConfig: WhitelistedAppConfig?
        var isRunning: Bool
        var isManualCapturing: Bool
    }

    private enum AppRowCaptureAction {
        case pauseAuto
        case resumeAuto
        case startManual
        case stopManual

        var title: String {
            switch self {
            case .pauseAuto:
                #tk("Pause Capture")
            case .resumeAuto:
                #tk("Resume Capture")
            case .startManual:
                #tk("Start Capture")
            case .stopManual:
                #tk("Stop Capture")
            }
        }

        var systemSymbol: SFSymbol {
            switch self {
            case .pauseAuto:
                .pauseFill
            case .resumeAuto:
                .playFill
            case .startManual:
                .recordCircle
            case .stopManual:
                .stopCircle
            }
        }

        var tint: Color {
            switch self {
            case .pauseAuto, .resumeAuto:
                .orange
            case .startManual, .stopManual:
                .red
            }
        }
    }

    private struct SelectedAppContext {
        var app: AppCaptureSummary
        var whitelistConfig: WhitelistedAppConfig?
        var isRunning: Bool
        var isCapturing: Bool

        var isWhitelisted: Bool {
            whitelistConfig != nil
        }
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

#Preview {
    ViewerView(store: .init(initialState: ViewerFeature.State()) {
        ViewerFeature()
    })
    .frame(width: 1080, height: 720)
}
