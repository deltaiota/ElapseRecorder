import SFSafeSymbols
import SwiftUI
import TranslateKit

struct AppSidebarRow: View {
    let app: AppCaptureSummary
    var isWhitelisted = true
    var isPaused = false
    var setCaptureState: (Bool) -> Void = { _ in }

    @State private var isShowingInfo = false

    private var identity: InstalledAppIdentity {
        InstalledAppIdentity(app: app)
    }

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(icon: identity.icon)
                .frame(height: 32)
                .opacity(isPaused ? 0.45 : 1)
                .overlay(alignment: .center) {
                    if isPaused {
                        Button {
                            setCaptureState(true)
                        } label: {
                            Image(systemSymbol: .pauseCircle)
                                .imageScale(.large)
                        }
                        .buttonBorderShape(.circle)
                        .buttonStyle(.plain)
                    }
                }

            VStack(alignment: .leading) {
                Text(identity.localizedName)
                    .lineLimit(1)
                    .foregroundStyle(isWhitelisted ? AnyShapeStyle(.primary) : AnyShapeStyle(.placeholder))

                CountSummary(
                    items: [
                        .init(value: app.sessionCount, systemSymbol: .clock),
                        .init(value: app.screenshotCount, systemSymbol: .photo),
                    ]
                )
                .foregroundStyle(isWhitelisted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.placeholder))
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
