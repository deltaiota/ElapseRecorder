import SwiftUI

/// A standalone, non-dismissable sheet shown while a timelapse is being encoded. It renders a
/// determinate progress bar with a percentage, exported/total frame counts, the chosen video
/// settings, and an estimated time remaining. Because the encoding runs off the main actor,
/// this sheet stays responsive and animates as progress is reported.
struct ExportProgressSheet: View {
    let status: TimelapseExportStatus
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header()

            progressRow()

            VStack(alignment: .leading, spacing: 4) {
                detailRow(frameCountText)
                detailRow(technicalSummary)
                detailRow(remainingTimeText)
            }

            Button(role: .cancel) {
                onCancel()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 340)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func header() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Exporting Timelapse…")
                .font(.headline)

            Text("Keep this window open until the export finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func progressRow() -> some View {
        HStack(spacing: 10) {
            ProgressView(value: status.fraction)
                .progressViewStyle(.linear)

            Text(status.fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func detailRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var frameCountText: String {
        let emitted = status.emittedFrames.formatted(.number)
        let total = status.totalFrames.formatted(.number)
        return String(localized: "\(emitted) of \(total) frames")
    }

    private var technicalSummary: String {
        let options = status.options
        var parts = [
            options.codec.title,
            options.container.title,
            String(localized: "\(options.framesPerSecond) fps"),
        ]
        if options.interpolationFrames > 0 {
            parts.append(String(localized: "\(options.interpolationFrames) crossfade frames"))
        }
        return parts.joined(separator: " · ")
    }

    private var remainingTimeText: String {
        guard let remaining = status.estimatedTimeRemaining(asOf: .now) else {
            return String(localized: "Estimating time remaining…")
        }
        let formatted = remaining.formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
        return String(localized: "About \(formatted) remaining")
    }
}

#Preview {
    ExportProgressSheet(
        status: TimelapseExportStatus(
            options: ExportOptions(codec: .h264, container: .mp4, framesPerSecond: 24, interpolationFrames: 3),
            totalFrames: 10000,
            emittedFrames: 4200,
            startedAt: .now.addingTimeInterval(-30)
        ),
        onCancel: {}
    )
}
