import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

/// Content column: the session list for the selected app (live sessions pinned, ended
/// sessions grouped by day) with the capture-settings inspector pinned to the bottom.
struct SessionListColumn: View {
    @Bindable var store: StoreOf<ViewerFeature>
    var settingsContext: CaptureSettingsView.Context?
    var defaultCaptureInterval: TimeInterval
    var actions: ViewerView.Actions

    @State private var collapsedSessionDaySections: [SessionDaySection.ID] = []
    @State private var sessionPendingDeletion: CaptureSessionSummary?

    private var isAppSelected: Bool {
        settingsContext != nil
    }

    var body: some View {
        List(selection: $store.sessionListSelection.sending(\.sessionListSelectionChanged)) {
            if isAppSelected {
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
            if let settingsContext {
                VStack(spacing: 0) {
                    Divider()

                    CaptureSettingsView(
                        context: settingsContext,
                        defaultCaptureInterval: defaultCaptureInterval,
                        actions: actions
                    )
                    .padding()
                }
                .background(.windowBackground)
            }
        }
        .overlay(alignment: .center) {
            if !isAppSelected {
                ContentUnavailableView(
                    "Choose an App",
                    systemSymbol: .appDashed,
                    description: Text("Captured sessions will appear here.")
                )
            }
        }
        .background(.windowBackground)
        .confirmationDialog(
            Text("Delete Session"),
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete", role: .destructive) {
                store.send(.deleteSessionButtonTapped(session))
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: { _ in
            Text("This permanently deletes the session and its screenshots.")
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: CaptureSessionSummary, isRecording: Bool) -> some View {
        let label = Label {
            VStack(alignment: .leading) {
                Text(session.startedAt, format: .dateTime.hour().minute())

                CountSummary(
                    items: sessionSummaryItems(session)
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
                        sessionPendingDeletion = session
                    } label: {
                        Label(TK.Action.delete, systemSymbol: .trash)
                    }
                    .tint(.red)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        sessionPendingDeletion = session
                    } label: {
                        Label("Delete Session", systemSymbol: .trash)
                    }
                }
        }
    }

    private func sessionSummaryItems(_ session: CaptureSessionSummary) -> [CountSummary.Item] {
        var items: [CountSummary.Item] = [
            .init(label: sessionDurationText(session), systemSymbol: .clock, isMonospaced: true),
            .init(value: session.windowCount, systemSymbol: .macwindow),
            .init(value: session.screenshotCount, systemSymbol: .photo),
        ]
        if session.sizeBytes > 0 {
            items.append(
                .init(
                    text: session.sizeBytes.formatted(.byteCount(style: .file)),
                    systemSymbol: .externaldrive,
                    isMonospaced: true
                )
            )
        }
        return items
    }

    /// Sessions still being captured (no end time). The app keeps at most one open session
    /// per app, so this is normally a single pinned row below "All Screenshots".
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

    private func sessionDurationText(_ session: CaptureSessionSummary) -> Text {
        // Record only the start and end; let SwiftUI render and update the timer.
        // An open (in-capture) session counts up live from its start; a finished
        // session shows the frozen total across its start...end interval.
        if let endedAt = session.endedAt {
            return Text(timerInterval: session.startedAt ... max(session.startedAt, endedAt), countsDown: false)
        }
        return Text(session.startedAt, style: .timer)
    }
}

#Preview {
    SessionListColumn(
        store: Store(
            initialState: {
                var state = ViewerFeature.State()
                state.selectedBundleIdentifier = "com.apple.TextEdit"
                state.selectedSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")
                state.sessions = [
                    CaptureSessionSummary(
                        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                        bundleIdentifier: "com.apple.TextEdit",
                        displayName: "TextEdit",
                        startedAt: Date.now.addingTimeInterval(-1800),
                        endedAt: nil,
                        windowCount: 2,
                        screenshotCount: 40
                    ),
                    CaptureSessionSummary(
                        id: UUID(),
                        bundleIdentifier: "com.apple.TextEdit",
                        displayName: "TextEdit",
                        startedAt: Date.now.addingTimeInterval(-90000),
                        endedAt: Date.now.addingTimeInterval(-86400),
                        windowCount: 1,
                        screenshotCount: 12
                    ),
                ]
                return state
            }()
        ) {
            ViewerFeature()
        },
        settingsContext: CaptureSettingsView.Context(
            app: AppCaptureSummary(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit", sessionCount: 2, screenshotCount: 52, lastCapturedAt: .now),
            whitelistConfig: WhitelistedAppConfig(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit", captureInterval: 5, isEnabled: true),
            isRunning: true,
            isCapturing: true
        ),
        defaultCaptureInterval: 5,
        actions: ViewerView.Actions()
    )
    .frame(width: 300, height: 640)
}
