import SFSafeSymbols
import SwiftUI

struct AppSidebarRow: View {
    let app: AppCaptureSummary
    var isWhitelisted = true

    @State private var isShowingInfo = false

    private var identity: InstalledAppIdentity {
        InstalledAppIdentity(app: app)
    }

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(icon: identity.icon)
                .frame(height: 32)

            VStack(alignment: .leading) {
                Text(identity.localizedName)
                    .lineLimit(1)

                CountSummary(
                    items: [
                        .init(value: app.sessionCount, systemSymbol: .clock),
                        .init(value: app.screenshotCount, systemSymbol: .photo),
                    ]
                )
                .foregroundStyle(.secondary)
                .font(.caption)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                isShowingInfo.toggle()
            } label: {
                Image(systemSymbol: .infoCircle)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Show app information")
            .popover(isPresented: $isShowingInfo, arrowEdge: .trailing) {
                AppInfoView(app: app, identity: identity)
            }
        }
        .opacity(isWhitelisted ? 1 : 0.45)
    }
}

#Preview {
    AppSidebarRow(
        app: AppCaptureSummary(
            bundleIdentifier: "com.apple.TextEdit",
            displayName: "TextEdit",
            sessionCount: 3,
            screenshotCount: 128,
            lastCapturedAt: .now
        )
    )
    .padding()
    .frame(width: 260)
}
