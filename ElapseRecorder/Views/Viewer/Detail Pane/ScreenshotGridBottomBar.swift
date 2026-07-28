import SFSafeSymbols
import SwiftUI

/// The detail-pane bottom bar: thumbnail-size controls, jump-to-latest, and export.
struct ScreenshotGridBottomBar: View {
    @Binding var gridItemSize: GridItemSize
    var onJumpToLatest: () -> Void
    var isExportDisabled: Bool = false
    var averageInterval: TimeInterval?
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
                .background {
                    // The visible buttons carry Cmd+= (larger) and Cmd+- (smaller).
                    // This hidden alias adds Cmd+Shift+= / numpad "+" as a second zoom-in binding.
                    Button("Zoom In") { gridItemSize = gridItemSize.steppedUp() }
                        .keyboardShortcut("+", modifiers: .command)
                        .opacity(0)
                        .accessibilityHidden(true)
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

                if let averageInterval {
                    Divider()
                        .frame(height: 16)

                    Label {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Average interval")
                            Text(averageInterval, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                            Text("s", comment: "Time unit suffix for seconds")
                        }
                    } icon: {
                        Image(systemSymbol: .timer)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Calculated from original capture timestamps and preserved after compaction.")
                }

                Spacer()

                Button("Export…") { onExport() }
                    .disabled(isExportDisabled)
                    .help("Export the shown screenshots as a timelapse video")
            }
            .padding()
        }
        .background(.bar)
    }
}

#Preview {
    ScreenshotGridBottomBar(
        gridItemSize: .constant(.default),
        onJumpToLatest: {},
        averageInterval: 1.48,
        onExport: {}
    )
    .frame(width: 520)
}
