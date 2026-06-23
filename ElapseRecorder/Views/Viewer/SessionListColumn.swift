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
