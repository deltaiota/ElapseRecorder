import AppKit
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct ScreenshotGrid: View {
    let entries: [CaptureTimelineEntry]
    @Binding var selectedIDs: Set<UUID>
    var itemSize: Double = 180
    var jumpToLatestTrigger: Int = 0
    var isQuickLookOpen: Bool = false
    var openQuickLook: (ScreenshotRecord) -> Void = { _ in }
    var revealScreenshot: (ScreenshotRecord) -> Void = { _ in }

    @State private var anchorID: UUID?
    @FocusState private var isFocused: Bool

    private let prefetchCount = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: itemSize), spacing: 14)], spacing: 14) {
                    ForEach(displayedEntries) { entry in
                        cell(for: entry)
                            .id(entry.id)
                    }
                }
                .padding()
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(.space) {
                openQuickLookForSelection()
                return .handled
            }
            .onChange(of: jumpToLatestTrigger) {
                guard let lastID = displayedEntries.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: isQuickLookOpen) { _, isOpen in
                // When the Quick Look panel closes it takes key focus with it, so the grid
                // would need a click before Space worked again. Re-grab focus so Space
                // reopens the preview immediately.
                if !isOpen {
                    DispatchQueue.main.async { isFocused = true }
                }
            }
            .overlay {
                if displayedEntries.isEmpty {
                    ContentUnavailableView(
                        "No screenshots",
                        systemSymbol: .photo,
                        description: Text("Captured frames will appear here.")
                    )
                }
            }
        }
    }

    /// A placeholder only conveys a *gap between* captures, so drop any unavailable
    /// entries at the very start or end of the timeline where there's nothing to gap.
    private var displayedEntries: [CaptureTimelineEntry] {
        var result = entries[...]
        while let first = result.first, case .unavailable = first {
            result = result.dropFirst()
        }
        while let last = result.last, case .unavailable = last {
            result = result.dropLast()
        }
        return Array(result)
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
                onQuickLook: { openQuickLook(record) },
                onReveal: { revealScreenshot(record) }
            )
        case let .unavailable(record):
            UnavailableCell(record: record)
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
    let onQuickLook: () -> Void
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
            .onTapGesture(perform: onClick)
            .contextMenu {
                Button {
                    onQuickLook()
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
        VStack(spacing: 6) {
            Image(systemSymbol: .rectangleDashed)
                .font(.title)
                .foregroundStyle(.secondary)

            Text(record.reason.title)
                .font(.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
