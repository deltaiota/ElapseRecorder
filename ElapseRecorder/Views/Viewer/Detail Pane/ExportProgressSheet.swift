import SwiftUI
import TranslateKit

/// A standalone, non-dismissable sheet shown while a timelapse is being encoded. It renders
/// a determinate progress bar with a percentage and a Cancel button. Because the encoding runs
/// off the main actor, this sheet stays responsive and animates as progress is reported.
struct ExportProgressSheet: View {
    let progress: Double
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Exporting Timelapse…")
                    .font(.headline)

                Text("Keep this window open until the export finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)

                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
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
        .frame(width: 320)
        .interactiveDismissDisabled()
    }
}

#Preview {
    ExportProgressSheet(progress: 0.42, onCancel: {})
}
