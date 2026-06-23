import SFSafeSymbols
import SwiftUI
import TranslateKit

struct ScreenshotGrid: View {
    let entries: [CaptureTimelineEntry]
    var selectedScreenshotID: UUID?
    let selectScreenshot: (ScreenshotRecord) -> Void
    var revealScreenshot: ((ScreenshotRecord) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 180), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(entries) { entry in
                    switch entry {
                    case let .screenshot(record):
                        ScreenshotCell(
                            record: record,
                            isSelected: selectedScreenshotID == record.id,
                            select: { selectScreenshot(record) },
                            reveal: revealScreenshot.map { reveal in { reveal(record) } }
                        )
                    case let .unavailable(record):
                        UnavailableCell(record: record)
                    }
                }
            }
            .padding()
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

private struct ScreenshotCell: View {
    let record: ScreenshotRecord
    let isSelected: Bool
    let select: () -> Void
    let reveal: (() -> Void)?

    var body: some View {
        Button(action: select) {
            ScreenshotThumbnailView(record: record)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    timestamp
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(borderStyle, lineWidth: isSelected ? 3 : 1)
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let reveal {
                Button {
                    reveal()
                } label: {
                    Label("Reveal in Finder", systemSymbol: .folder)
                }
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

    private var borderStyle: AnyShapeStyle {
        if isSelected {
            AnyShapeStyle(Color.accentColor)
        } else {
            AnyShapeStyle(.separator)
        }
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
        let duration = Duration.seconds(seconds)
        let formatted = duration.formatted(.time(pattern: .minuteSecond))
        return #tk("Unavailable for \(formatted)")
    }
}

#Preview {
    ScreenshotGrid(entries: [], selectScreenshot: { _ in })
        .frame(width: 360, height: 240)
}
