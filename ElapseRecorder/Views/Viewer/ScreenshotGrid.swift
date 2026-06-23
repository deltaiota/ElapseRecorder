import AppKit
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct ScreenshotGrid: View {
    let entries: [CaptureTimelineEntry]
    @Binding var selectedIDs: Set<UUID>
    var openQuickLook: (ScreenshotRecord) -> Void = { _ in }
    var revealScreenshot: (ScreenshotRecord) -> Void = { _ in }

    @AppStorage("screenshotGridItemSize") private var itemSize: Double = 180
    @State private var anchorID: UUID?
    @FocusState private var isFocused: Bool

    private let prefetchCount = 6
    private static let sizeRange: ClosedRange<Double> = 120 ... 360

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: itemSize), spacing: 14)], spacing: 14) {
                    ForEach(entries) { entry in
                        cell(for: entry)
                            .id(entry.id)
                    }
                }
                .padding()
                .padding(.bottom, 44)
            }
            .focusable()
            .focused($isFocused)
            .onKeyPress(.space) {
                openQuickLookForSelection()
                return .handled
            }
            .overlay(alignment: .bottom) {
                controlBar(proxy: proxy)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No screenshots",
                        systemSymbol: .photo,
                        description: Text("Captured frames will appear here.")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for entry: CaptureTimelineEntry) -> some View {
        switch entry {
        case let .screenshot(record):
            ScreenshotCell(
                record: record,
                prefetch: prefetchByID[record.id] ?? [],
                isSelected: selectedIDs.contains(record.id),
                onClick: { handleClick(record) },
                onDoubleClick: { openQuickLook(record) },
                onReveal: { revealScreenshot(record) }
            )
        case let .unavailable(record):
            UnavailableCell(record: record)
        }
    }

    @ViewBuilder
    private func controlBar(proxy: ScrollViewProxy) -> some View {
        if !entries.isEmpty {
            HStack(spacing: 12) {
                Image(systemSymbol: .photo)
                    .foregroundStyle(.secondary)
                Slider(value: $itemSize, in: Self.sizeRange)
                    .frame(width: 120)
                Image(systemSymbol: .photoOnRectangle)
                    .foregroundStyle(.secondary)

                Divider().frame(height: 16)

                Button {
                    if let lastID = entries.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                } label: {
                    Label("Jump to Latest", systemSymbol: .arrowDownToLine)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Jump to latest")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .padding(.bottom, 12)
        }
    }

    private func openQuickLookForSelection() {
        guard let id = selectedIDs.first ?? orderedScreenshots.first?.id,
              let record = orderedScreenshots.first(where: { $0.id == id })
        else { return }
        openQuickLook(record)
    }

    private func handleClick(_ record: ScreenshotRecord) {
        isFocused = true
        let flags = NSEvent.modifierFlags
        let ordered = orderedScreenshots.map(\.id)

        if flags.contains(.command) {
            if selectedIDs.contains(record.id) {
                selectedIDs.remove(record.id)
            } else {
                selectedIDs.insert(record.id)
                anchorID = record.id
            }
        } else if flags.contains(.shift),
                  let anchor = anchorID,
                  let start = ordered.firstIndex(of: anchor),
                  let end = ordered.firstIndex(of: record.id)
        {
            let bounds = start <= end ? start ... end : end ... start
            selectedIDs = Set(ordered[bounds])
        } else {
            selectedIDs = [record.id]
            anchorID = record.id
        }
    }

    private var orderedScreenshots: [ScreenshotRecord] {
        entries.compactMap { entry in
            if case let .screenshot(record) = entry { return record }
            return nil
        }
    }

    private var prefetchByID: [UUID: [ScreenshotRecord]] {
        let records = orderedScreenshots
        var map: [UUID: [ScreenshotRecord]] = [:]
        for (index, record) in records.enumerated() {
            let start = index + 1
            let end = min(start + prefetchCount, records.count)
            map[record.id] = start < end ? Array(records[start ..< end]) : []
        }
        return map
    }
}

private struct ScreenshotCell: View {
    let record: ScreenshotRecord
    var prefetch: [ScreenshotRecord]
    let isSelected: Bool
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let onReveal: () -> Void

    var body: some View {
        ScreenshotThumbnailView(record: record, prefetch: prefetch)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                timestamp
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                                  lineWidth: isSelected ? 3 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture(count: 2, perform: onDoubleClick)
            .onTapGesture(count: 1, perform: onClick)
            .contextMenu {
                Button {
                    onDoubleClick()
                } label: {
                    Label("Quick Look", systemSymbol: .eye)
                }
                Button {
                    onReveal()
                } label: {
                    Label("Reveal in Finder", systemSymbol: .folder)
                }
            }
            .help(Text(record.capturedAt, format: .dateTime.hour().minute().second()))
    }

    private var timestamp: some View {
        Text(record.capturedAt, format: .dateTime.hour().minute().second())
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(6)
    }
}

private struct UnavailableCell: View {
    let record: CaptureUnavailableRecord

    var body: some View {
        VStack(spacing: 8) {
            Image(systemSymbol: .rectangleDashed)
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(record.reason.title)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Text(durationText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 10, contentMode: .fit)
    }

    private var durationText: String {
        let seconds = max(0, record.endedAt.timeIntervalSince(record.startedAt))
        let formatted = Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
        return #tk("Unavailable for \(formatted)")
    }
}
