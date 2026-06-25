import ComposableArchitecture
import Defaults
import QuickLook
import SFSafeSymbols
import SwiftUI
import TranslateKit

/// Detail column: the screenshot grid for the current selection, its bottom bar, and the
/// Quick Look preview. Owns the grid-size preference and the jump-to-latest trigger.
struct DetailPaneView: View {
    @Bindable var store: StoreOf<ViewerFeature>

    @Default(.screenshotGridItemSize) private var gridItemSize
    @Default(.exportFramesPerSecond) private var exportFramesPerSecond
    @State private var jumpToLatestTrigger = 0

    var body: some View {
        Group {
            if store.isShowingFlatGallery {
                grid(entries: store.flatTimelineEntries)
                    .navigationTitle("All Screenshots")
                    .safeAreaInset(edge: .bottom) {
                        bottomBar()
                    }
            } else if store.selectedSessionID != nil {
                sessionDetail()
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
        .overlay {
            if let progress = store.exportProgress {
                exportProgressOverlay(progress)
            }
        }
        .quickLookPreview(
            $store.quickLookURL.sending(\.quickLookURLChanged),
            in: currentScreenshotURLs
        )
    }

    private func exportProgressOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView(value: progress) {
                    Text("Exporting Timelapse…")
                        .font(.headline)
                } currentValueLabel: {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 240)

                Button("Cancel", role: .cancel) {
                    store.send(.exportCancelButtonTapped)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Timeline graph or a window's grid, under a persistent breadcrumb.
    @ViewBuilder
    private func sessionDetail() -> some View {
        VStack(spacing: 0) {
            breadcrumbHeader()

            Divider()

            if store.isShowingTimelineGraph {
                timelineGraph()
            } else {
                grid(entries: store.windowTimelineEntries)
                    .safeAreaInset(edge: .bottom) {
                        bottomBar()
                    }
            }
        }
    }

    @ViewBuilder
    private func breadcrumbHeader() -> some View {
        HStack(spacing: 8) {
            if store.isShowingTimelineGraph {
                Text("Timeline")
                    .fontWeight(.semibold)
            } else {
                Button("Timeline") {
                    store.send(.windowSelected(nil))
                }
                .buttonStyle(.plain)

                Image(systemSymbol: .chevronCompactRight)
                    .foregroundStyle(.tertiary)

                windowPicker()
                    .buttonStyle(.borderless)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func windowPicker() -> some View {
        Picker(
            "Window",
            selection: $store.windowPickerSelection.sending(\.windowPickerSelectionChanged)
        ) {
            ForEach(store.windows) { window in
                Text(windowMenuTitle(window))
                    .tag(ViewerFeature.State.WindowPickerSelection.window(id: window.id))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func windowMenuTitle(_ window: WindowCaptureSummary) -> String {
        if let label = window.label, !label.isEmpty {
            return #tk("Window \(window.displayNumber): \(label)")
        }
        return #tk("Window \(window.displayNumber)")
    }

    @ViewBuilder
    private func timelineGraph() -> some View {
        if let timeline = store.sessionTimeline {
            TimelineGraphView(
                timeline: timeline,
                selectedWindowID: store.selectedWindowID,
                selectedSegmentID: store.selectedSegment?.id,
                onSelectWindow: { store.send(.windowSelected($0)) },
                onSelectSegment: { windowID, segment in
                    store.send(.windowSegmentSelected(windowID: windowID, segment: segment))
                }
            )
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func grid(entries: [CaptureTimelineEntry]) -> some View {
        ScreenshotGrid(
            entries: entries,
            selectedIDs: $store.selectedScreenshotIDs.sending(\.screenshotSelectionChanged),
            itemSize: gridItemSize.value,
            jumpToLatestTrigger: jumpToLatestTrigger,
            isQuickLookOpen: store.quickLookURL != nil,
            openQuickLook: { store.send(.quickLookURLChanged($0.fileURL)) },
            revealScreenshot: { store.send(.revealScreenshotInFinder($0)) }
        )
    }

    @ViewBuilder
    private func bottomBar() -> some View {
        ScreenshotGridBottomBar(
            gridItemSize: $gridItemSize,
            onJumpToLatest: { jumpToLatestTrigger += 1 },
            isExportDisabled: exportScopeURLs.isEmpty || store.exportProgress != nil,
            onExport: {
                store.send(.exportTimelapseRequested(
                    urls: exportScopeURLs,
                    framesPerSecond: exportFramesPerSecond
                ))
            }
        )
    }

    /// Ordered screenshot file URLs for the grid currently shown. Quick Look uses these as
    /// its navigable item set so arrow keys move between frames.
    private var currentScreenshotURLs: [URL] {
        let entries = store.isShowingFlatGallery ? store.flatTimelineEntries : store.windowTimelineEntries
        return entries.compactMap { entry in
            if case let .screenshot(record) = entry { return record.fileURL }
            return nil
        }
    }

    /// What a timelapse export covers: the multi-selection if the user picked several
    /// frames, otherwise the whole current grid — always in chronological order.
    private var exportScopeURLs: [URL] {
        let entries = store.isShowingFlatGallery ? store.flatTimelineEntries : store.windowTimelineEntries
        let selection = store.selectedScreenshotIDs
        let useSelection = selection.count >= 2

        return entries.compactMap { entry in
            guard case let .screenshot(record) = entry else { return nil }
            if useSelection, !selection.contains(record.id) { return nil }
            return record.fileURL
        }
    }
}

#Preview {
    DetailPaneView(
        store: Store(
            initialState: {
                var state = ViewerFeature.State()
                state.selectedBundleIdentifier = "com.apple.TextEdit"
                state.selectedSessionID = UUID()
                state.sessionTimeline = SessionTimeline(
                    sessionID: state.selectedSessionID!,
                    startedAt: Date(timeIntervalSince1970: 0),
                    endedAt: Date(timeIntervalSince1970: 480),
                    lanes: [
                        WindowLane(
                            windowID: UUID(),
                            displayNumber: 1,
                            systemWindowID: 1,
                            bornAt: Date(timeIntervalSince1970: 0),
                            diedAt: Date(timeIntervalSince1970: 480),
                            segments: [
                                WindowTitleSegment(id: UUID(), title: "Untitled", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 200), screenshotCount: 4),
                                WindowTitleSegment(id: UUID(), title: "Notes.txt", startedAt: Date(timeIntervalSince1970: 200), endedAt: Date(timeIntervalSince1970: 480), screenshotCount: 9),
                            ],
                            screenshotCount: 13
                        ),
                    ],
                    unavailableSpans: []
                )
                return state
            }()
        ) {
            ViewerFeature()
        }
    )
    .frame(width: 720, height: 600)
}
