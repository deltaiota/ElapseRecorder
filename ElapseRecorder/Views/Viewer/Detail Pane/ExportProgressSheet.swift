import SwiftUI

/// A standalone, non-dismissable sheet shown while a timelapse is being encoded. It renders a
/// determinate progress bar with a percentage and a form describing the export: exported/total
/// frame counts, the chosen video settings, and an estimated time remaining. Because the
/// encoding runs off the main actor, this sheet stays responsive and animates as progress is
/// reported.
struct ExportProgressSheet: View {
    let status: TimelapseExportStatus
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header()

            progressRow()

            detailsForm()

            Button(role: .cancel) {
                onCancel()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 360)
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
    private func detailsForm() -> some View {
        Form {
            LabeledContent("Frames", value: framesValue)
            LabeledContent("Format", value: formatValue)
            LabeledContent("Frame Rate", value: frameRateValue)
            if status.options.interpolationFrames > 0 {
                LabeledContent("Interpolation", value: interpolationValue)
            }
            LabeledContent("Time Remaining", value: remainingTimeValue)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .padding(-20)
    }

    private var framesValue: String {
        let emitted = status.emittedFrames.formatted(.number)
        let total = status.totalFrames.formatted(.number)
        return "\(emitted) / \(total)"
    }

    private var formatValue: String {
        "\(status.options.codec.title) · \(status.options.container.title)"
    }

    private var frameRateValue: String {
        String(localized: "\(status.options.framesPerSecond) fps")
    }

    private var interpolationValue: String {
        String(localized: "\(status.options.interpolationFrames) crossfade frames")
    }

    private var remainingTimeValue: String {
        guard let remaining = status.estimatedTimeRemaining(asOf: .now) else {
            return String(localized: "Estimating…")
        }
        return remaining.formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
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
