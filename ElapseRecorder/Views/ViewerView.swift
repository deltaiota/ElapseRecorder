import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct ViewerView: View {
    @Bindable var store: StoreOf<ViewerFeature>

    var captureConfiguration = CaptureConfiguration()
    var actions = Actions()

    @State private var isShowingApplicationSelection = false
    @State private var collapsedSessionDaySections: [SessionDaySection.ID] = []
    @State private var jumpToLatestTrigger = 0
    @AppStorage("screenshotGridItemSize") private var gridItemSize: Double = 180

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
        .navigationTitle("Elapse Recorder")
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
                isCapturing: context.isCapturing,
                unavailableReason: context.unavailableReason
            ),
            actions: .init(
                setAutoCaptureEnabled: { isEnabled in
                    setCaptureState(context.app, isEnabled)
                },
                startCapture: {
                    startCapture(context.app)
                },
                stopCapture: {
                    stopCapture(context.app)
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
            isCapturing: activeCaptureBundleIdentifiers.contains(app.bundleIdentifier),
            unavailableReason: captureUnavailableReasonsByBundleIdentifier[app.bundleIdentifier]
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
            setCaptureState(app, false)
        case .resumeAuto:
            setCaptureState(app, true)
        case .startCapture:
            startCapture(app)
        case .stopCapture:
            stopCapture(app)
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

                ForEach(activeSessions) { session in
                    sessionRow(session, isRecording: true)
                }

                ForEach(sessionDaySections) { section in
                    Section(isExpanded: $collapsedSessionDaySections[contains: section.id].negate()) {
                        ForEach(section.sessions) { session in
                            sessionRow(session, isRecording: false)
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
                screenshotGrid(entries: store.flatTimelineEntries)
                    .navigationTitle("All Screenshots")
                    .safeAreaInset(edge: .bottom) {
                        detailBottomBar(showsWindowPicker: false)
                    }
            } else if store.selectedSessionID != nil {
                screenshotGrid(entries: store.windowTimelineEntries)
                    .safeAreaInset(edge: .bottom) {
                        detailBottomBar(showsWindowPicker: true)
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
        .background(
            QuickLookPresenter(
                urls: currentScreenshotURLs,
                openURL: store.quickLookURL,
                onNavigate: { index in
                    let urls = currentScreenshotURLs
                    guard urls.indices.contains(index) else { return }
                    store.send(.quickLookNavigated(urls[index]))
                },
                onClose: { store.send(.quickLookURLChanged(nil)) }
            )
        )
    }

    @ViewBuilder
    private func screenshotGrid(entries: [CaptureTimelineEntry]) -> some View {
        ScreenshotGrid(
            entries: entries,
            selectedIDs: $store.selectedScreenshotIDs.sending(\.screenshotSelectionChanged),
            itemSize: gridItemSize,
            jumpToLatestTrigger: jumpToLatestTrigger,
            isQuickLookOpen: store.quickLookURL != nil,
            openQuickLook: { store.send(.quickLookURLChanged($0.fileURL)) },
            revealScreenshot: { store.send(.revealScreenshotInFinder($0)) }
        )
    }

    @ViewBuilder
    private func detailBottomBar(showsWindowPicker: Bool) -> some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemSymbol: .photo)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Slider(value: $gridItemSize, in: 120 ... 360)
                        .frame(width: 110)
                    Image(systemSymbol: .photoOnRectangle)
                        .foregroundStyle(.secondary)
                }

                Button {
                    jumpToLatestTrigger += 1
                } label: {
                    Label("Jump to Latest", systemSymbol: .arrowDownToLine)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Jump to latest")

                if showsWindowPicker {
                    Divider().frame(height: 16)

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
                }

                Spacer()

                Button("Export…") {}
            }
            .padding()
        }
        .background(.bar)
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
                        stopCapture(context.app)
                    } label: {
                        Text("Stop")

                        Image(systemSymbol: .stopCircle)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        startCapture(context.app)
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

    private var whitelistConfigs: [WhitelistedAppConfig] {
        captureConfiguration.whitelistConfigs
    }

    private var defaultCaptureInterval: TimeInterval {
        captureConfiguration.defaultCaptureInterval
    }

    private var activeCaptureBundleIdentifiers: Set<String> {
        captureConfiguration.activeCaptureBundleIdentifiers
    }

    private var runningApplicationBundleIdentifiers: Set<String> {
        captureConfiguration.runningApplicationBundleIdentifiers
    }

    private var captureUnavailableReasonsByBundleIdentifier: [String: CaptureUnavailableReason] {
        captureConfiguration.unavailableReasonsByBundleIdentifier
    }

    private func whitelistApps(_ configs: [WhitelistedAppConfig]) {
        actions.whitelistApps(configs)
    }

    private func setCaptureState(_ app: AppCaptureSummary, _ isEnabled: Bool) {
        actions.setCaptureState(app, isEnabled)
    }

    private func setCaptureInterval(_ app: AppCaptureSummary, _ interval: TimeInterval) {
        actions.setCaptureInterval(app, interval)
    }

    private func setCaptureMode(_ app: AppCaptureSummary, _ captureMode: CaptureMode) {
        actions.setCaptureMode(app, captureMode)
    }

    private func startCapture(_ app: AppCaptureSummary) {
        actions.startCapture(app)
    }

    private func stopCapture(_ app: AppCaptureSummary) {
        actions.stopCapture(app)
    }

    private func removeFromWhitelist(_ app: AppCaptureSummary) {
        actions.removeFromWhitelist(app)
    }

    private func addToWhitelist(_ app: AppCaptureSummary) {
        actions.addToWhitelist(app)
    }

    private func deleteAllCaptures(_ app: AppCaptureSummary) {
        actions.deleteAllCaptures(app)
    }

    @ViewBuilder
    private func sessionRow(_ session: CaptureSessionSummary, isRecording: Bool) -> some View {
        let label = Label {
            VStack(alignment: .leading) {
                Text(session.startedAt, format: .dateTime.hour().minute())

                CountSummary(
                    items: [
                        .init(label: sessionDurationText(session), systemSymbol: .clock, isMonospaced: true),
                        .init(value: session.windowCount, systemSymbol: .macwindow),
                        .init(value: session.screenshotCount, systemSymbol: .photo),
                    ]
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        } icon: {
            Image(systemSymbol: isRecording ? .recordCircle : .clock)
                .foregroundStyle(isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .symbolEffect(.pulse, options: .repeating, isActive: isRecording)
        }
        .tag(ViewerFeature.State.SessionListSelection.session(id: session.id))

        // A recording session can't be deleted while it's open, so only ended sessions
        // expose delete actions.
        if isRecording {
            label
        } else {
            label
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
    }

    /// Ordered screenshot file URLs for the grid currently shown in the detail pane.
    /// Quick Look uses these as its navigable item set so arrow keys move between frames.
    private var currentScreenshotURLs: [URL] {
        let entries = store.isShowingFlatGallery ? store.flatTimelineEntries : store.windowTimelineEntries
        return entries.compactMap { entry in
            if case let .screenshot(record) = entry { return record.fileURL }
            return nil
        }
    }

    /// Sessions still being captured (no end time). The app keeps at most one open
    /// session per app, so this is normally a single pinned row below "All Screenshots".
    private var activeSessions: [CaptureSessionSummary] {
        store.sessions
            .filter { $0.endedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var sessionDaySections: [SessionDaySection] {
        let calendar = Calendar.current
        let endedSessions = store.sessions.filter { $0.endedAt != nil }
        let groupedSessions = Dictionary(grouping: endedSessions) { session in
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

    private func sessionDurationText(_ session: CaptureSessionSummary) -> Text {
        // Record only the start and end; let SwiftUI render and update the timer.
        // An open (in-capture) session counts up live from its start; a finished
        // session shows the frozen total across its start...end interval.
        if let endedAt = session.endedAt {
            return Text(timerInterval: session.startedAt ... max(session.startedAt, endedAt), countsDown: false)
        }
        return Text(session.startedAt, style: .timer)
    }

    private func windowTitle(_ window: WindowCaptureSummary) -> String {
        if let label = window.label, !label.isEmpty {
            return #tk("Window \(window.displayNumber): \(label)")
        }
        return #tk("Window \(window.displayNumber)")
    }

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
