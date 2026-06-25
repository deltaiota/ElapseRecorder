import ComposableArchitecture
import Defaults
import QuickLook
import SFSafeSymbols
import SwiftUI

/// Detail column: the screenshot grid for the current selection, its bottom bar, and the
/// Quick Look preview. Owns the grid-size preference and the jump-to-latest trigger.
struct DetailPaneView: View {
    @Bindable var store: StoreOf<ViewerFeature>

    @Default(.screenshotGridItemSize) private var gridItemSize
    @State private var jumpToLatestTrigger = 0

    var body: some View {
        Group {
            if store.isShowingFlatGallery {
                grid(entries: store.flatTimelineEntries)
                    .navigationTitle("All Screenshots")
                    .safeAreaInset(edge: .bottom) {
                        bottomBar()
                    }
            } else if store.isShowingTimelineGraph {
                timelineGraph
            } else if store.selectedSessionID != nil {
                grid(entries: store.windowTimelineEntries)
                    .navigationTitle(windowGridTitle)
                    .safeAreaInset(edge: .top) {
                        gridBreadcrumb
                    }
                    .safeAreaInset(edge: .bottom) {
                        bottomBar()
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
        .background {
            // The visible bottom-bar buttons carry Cmd+= (larger) and Cmd+- (smaller).
            // This hidden alias adds Cmd+Shift+= / numpad "+" as a second zoom-in binding.
            Button("Zoom In") { gridItemSize = gridItemSize.steppedUp() }
                .keyboardShortcut("+", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .quickLookPreview(
            $store.quickLookURL.sending(\.quickLookURLChanged),
            in: currentScreenshotURLs
        )
    }

    @ViewBuilder
    private var timelineGraph: some View {
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

    private var windowGridTitle: String {
        if let segment = store.selectedSegment, let title = segment.title, !title.isEmpty {
            return title
        }
        if let windowID = store.selectedWindowID,
           let window = store.windows.first(where: { $0.id == windowID })
        {
            return window.label ?? "Window \(window.displayNumber)"
        }
        return ""
    }

    /// Breadcrumb above a window's grid: a back button to the timeline plus the current
    /// window / title segment.
    private var gridBreadcrumb: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    store.send(.windowSelected(nil))
                } label: {
                    Label("Timeline", systemSymbol: .chevronBackward)
                }
                .buttonStyle(.borderless)
                .help("Back to timeline")

                Image(systemSymbol: .chevronCompactRight)
                    .foregroundStyle(.tertiary)

                Text(windowGridTitle)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
        }
        .background(.bar)
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
            onExport: {}
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
}
