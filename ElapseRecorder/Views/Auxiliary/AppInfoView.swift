import AppKit
import SFSafeSymbols
import SwiftUI

struct AppInfoView: View {
    let app: AppCaptureSummary
    let identity: InstalledAppIdentity

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                AppIconView(icon: identity.icon)
                    .frame(height: 54)

                VStack(alignment: .leading, spacing: 5) {
                    VStack(alignment: .leading, spacing: -4) {
                        Text(identity.localizedName)
                            .font(.title3)
                            .bold()

                        Text(identity.bundleIdentifier)
                            .textSelection(.enabled)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }

                    if let appURL = identity.appURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([appURL])
                        } label: {
                            HStack(spacing: 2) {
                                Text(appURL.path(percentEncoded: false).replacing(/\/$/, with: ""))
                                    .underline()

                                Image(systemSymbol: .arrowRightCircleFill)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 16)

            Form {
                Section {
                    LabeledContent("Sessions") {
                        Text(app.sessionCount, format: .number)
                            .monospaced()
                    }

                    LabeledContent("Screenshots") {
                        Text(app.screenshotCount, format: .number)
                            .monospaced()
                    }

                    if app.sizeBytes > 0 {
                        LabeledContent("Disk Space") {
                            Text(app.sizeBytes.formatted(.byteCount(style: .file)))
                                .monospaced()
                        }
                    }
                }

                Section {
                    LabeledContent("Recorded Name") {
                        Text(identity.recordedName)
                    }

                    if let lastCapturedAt = app.lastCapturedAt {
                        LabeledContent("Last Capture") {
                            Text(lastCapturedAt, format: .dateTime)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(-20)
            .frame(width: 300)
        }
        .padding()
    }
}

#Preview {
    AppInfoView(
        app: AppCaptureSummary(bundleIdentifier: "com.apple.Safari", displayName: "Safari", sessionCount: 5, screenshotCount: 210, lastCapturedAt: .now, sizeBytes: 48_500_000),
        identity: InstalledAppIdentity(bundleIdentifier: "com.apple.Safari", recordedName: "Safari")
    )
    .padding()
    .frame(width: 360)
}
