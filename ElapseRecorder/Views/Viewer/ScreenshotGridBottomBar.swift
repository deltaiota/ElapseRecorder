import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

/// The detail-pane bottom bar: thumbnail-size controls, jump-to-latest, an optional
/// window picker, and export.
struct ScreenshotGridBottomBar: View {
    @Binding var gridItemSize: GridItemSize
    var showsWindowPicker: Bool
    var windows: [WindowCaptureSummary]
    @Binding var windowSelection: ViewerFeature.State.WindowPickerSelection
    var onJumpToLatest: () -> Void
    var onExport: () -> Void
    
    @State private var gridItemSizeSmallerButtonAnimationTrigger: Int = 0
    @State private var gridItemSizeLargerButtonAnimationTrigger: Int = 0
    @State private var jumpToLatestButtonAnimationTrigger: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Button {
                        gridItemSize = gridItemSize.steppedDown()
                        gridItemSizeSmallerButtonAnimationTrigger += 1
                    } label: {
                        Image(systemSymbol: .photo)
                            .imageScale(.small)
                            .symbolEffect(.bounce, value: gridItemSizeSmallerButtonAnimationTrigger)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(gridItemSize.isAtMinimum)
                    .help("Smaller thumbnails")

                    Slider(
                        value: Binding(
                            get: { gridItemSize.value },
                            set: { gridItemSize = GridItemSize($0) }
                        ),
                        in: GridItemSize.minimum ... GridItemSize.maximum
                    )
                    .frame(width: 110)

                    Button {
                        gridItemSize = gridItemSize.steppedUp()
                        gridItemSizeLargerButtonAnimationTrigger += 1
                    } label: {
                        Image(systemSymbol: .photo)
                            .imageScale(.large)
                            .symbolEffect(.bounce, value: gridItemSizeLargerButtonAnimationTrigger)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(gridItemSize.isAtMaximum)
                    .help("Larger thumbnails")
                }

                Button {
                    onJumpToLatest()
                    jumpToLatestButtonAnimationTrigger += 1
                } label: {
                    Label("Jump to Latest", systemSymbol: .arrowDownToLine)
                        .labelStyle(.iconOnly)
                        .symbolEffect(.wiggle.byLayer, value: jumpToLatestButtonAnimationTrigger)
                }
                .buttonStyle(.borderless)
                .help("Jump to latest")

                if showsWindowPicker {
                    Divider().frame(height: 16)

                    Picker("Window", selection: $windowSelection) {
                        Text("All Windows")
                            .tag(ViewerFeature.State.WindowPickerSelection.all)

                        if !windows.isEmpty {
                            Divider()

                            ForEach(windows) { window in
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

                Button("Export…") { onExport() }
            }
            .padding()
        }
        .background(.bar)
    }

    private func windowTitle(_ window: WindowCaptureSummary) -> String {
        if let label = window.label, !label.isEmpty {
            return #tk("Window \(window.displayNumber): \(label)")
        }
        return #tk("Window \(window.displayNumber)")
    }
}
