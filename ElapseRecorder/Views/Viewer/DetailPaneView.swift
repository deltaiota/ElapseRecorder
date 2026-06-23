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
                        bottomBar(showsWindowPicker: false)
                    }
            } else if store.selectedSessionID != nil {
                grid(entries: store.windowTimelineEntries)
                    .safeAreaInset(edge: .bottom) {
                        bottomBar(showsWindowPicker: true)
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
    private func bottomBar(showsWindowPicker: Bool) -> some View {
        ScreenshotGridBottomBar(
            gridItemSize: $gridItemSize,
            showsWindowPicker: showsWindowPicker,
            windows: store.windows,
            windowSelection: $store.windowPickerSelection.sending(\.windowPickerSelectionChanged),
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
