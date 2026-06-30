import AppKit
import SwiftUI

/// A short, localized "About" page shown from the native App menu › About Elapse Recorder.
struct AboutView: View {
    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Elapse Recorder")
                    .font(.title2.bold())

                Text("Version \(shortVersion) (\(buildVersion))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Capture whitelisted apps on a schedule and turn long, fragmented sessions into a fast-forward timelapse.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: "© KrLite")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .frame(width: 340)
    }
}

#Preview {
    AboutView()
}
