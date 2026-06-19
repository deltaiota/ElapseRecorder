import SFSafeSymbols
import SwiftUI

struct ScreenshotGrid: View {
    let records: [ScreenshotRecord]
    let selectScreenshot: (ScreenshotRecord) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(records) { record in
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
                }
            }
            .padding()
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "No screenshots",
                    systemSymbol: .photo,
                    description: Text("Captured frames will appear here.")
                )
            }
        }
    }
}

#Preview {
    ScreenshotGrid(records: [], selectScreenshot: { _ in })
        .frame(width: 360, height: 240)
}
