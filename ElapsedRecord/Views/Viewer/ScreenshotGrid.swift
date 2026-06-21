import SFSafeSymbols
import SwiftUI

struct ScreenshotGrid: View {
    let entries: [CaptureTimelineEntry]
    let selectScreenshot: (ScreenshotRecord) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(entries) { entry in
                    timelineEntry(entry)
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

    @ViewBuilder
    private func timelineEntry(_ entry: CaptureTimelineEntry) -> some View {
        switch entry {
        case let .screenshot(record):
            Button {
                selectScreenshot(record)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ScreenshotThumbnailView(record: record)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(record.capturedAt, format: .dateTime.hour().minute().second())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

        case let .unavailable(record):
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.yellow.opacity(0.14))

                    VStack(spacing: 8) {
                        Image(systemSymbol: .rectangleDashed)
                            .font(.largeTitle)
                            .foregroundStyle(.yellow)

                        Text(record.reason.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)

                Text(record.startedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ScreenshotGrid(entries: [], selectScreenshot: { _ in })
        .frame(width: 360, height: 240)
}
