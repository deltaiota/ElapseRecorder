import SFSafeSymbols
import SwiftUI
import TranslateKit

struct AppSidebarRow: View {
    let app: AppCaptureSummary
    let captureMode: CaptureMode
    var isRunning = true
    var isWhitelisted = true
    var isPaused = true
    var isManualCapturing = false
    var captureInterval: TimeInterval?
    var setCaptureState: (Bool) -> Void = { _ in }
    var startManualCapture: () -> Void = {}
    var stopManualCapture: () -> Void = {}

    @State private var isShowingInfo = false

    private var identity: InstalledAppIdentity {
        InstalledAppIdentity(app: app)
    }
    
    private var opacity: CGFloat {
        guard isRunning else { return 0.45 }
        return switch captureMode {
        case .auto: isPaused ? 0.45 : 1
        case .manual: isManualCapturing ? 0.45 : 1
        }
    }

    var body: some View {
        HStack {
            AppIconView(icon: identity.icon)
                .frame(height: 32)
                .opacity(opacity)
                .overlay(alignment: .center) {
                    if isRunning {
                        Group {
                            switch captureMode {
                            case .auto where isPaused:
                                Button {
                                    setCaptureState(true)
                                } label: {
                                    Image(systemSymbol: .playCircle)
                                }
                            case .manual where isManualCapturing:
                                Button {
                                    stopManualCapture()
                                } label: {
                                    Image(systemSymbol: .stopCircle)
                                        .foregroundStyle(.red)
                                }
                            default: EmptyView()
                            }
                        }
                        .buttonBorderShape(.circle)
                        .buttonStyle(.plain)
                        .imageScale(.large)
                    }
                }
                .fixedSize()
                .onTapGesture {
                    if isRunning {
                        switch captureMode {
                        case .auto where !isPaused: setCaptureState(false)
                        case .manual where !isManualCapturing: startManualCapture()
                        default: break
                        }
                    }
                }

            VStack(alignment: .leading) {
                Text(identity.localizedName)
                    .lineLimit(1)
                    .foregroundStyle(isWhitelisted ? AnyShapeStyle(.primary) : AnyShapeStyle(.placeholder))

                CountSummary(
                    items: countSummaryItems
                )
                .foregroundStyle(isWhitelisted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.placeholder))
                .font(.caption)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

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

    private var countSummaryItems: [CountSummary.Item] {
        var items: [CountSummary.Item] = [
            .init(value: app.sessionCount, systemSymbol: .film),
            .init(value: app.screenshotCount, systemSymbol: .photo),
        ]

        if let captureInterval {
            items.append(
                .init(
                    text: captureIntervalLabel(captureInterval),
                    systemSymbol: .timer,
                    isMonospaced: true
                )
            )
        }

        return items
    }

    private func captureIntervalLabel(_ interval: TimeInterval) -> String {
        let totalSeconds = max(1, Int(interval.rounded()))
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
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
        ),
        captureMode: .auto
    )
    .padding()
    .frame(width: 260)
}
