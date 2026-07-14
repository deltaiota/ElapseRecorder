import SFSafeSymbols
import SwiftUI
import TranslateKit

struct AppSidebarRow: View {
    let model: Model
    var actions = Actions()

    @State private var isShowingInfo = false
    @State private var isShowingCaptureUnavailableReason = false

    private var identity: InstalledAppIdentity {
        InstalledAppIdentity(app: model.app)
    }

    var body: some View {
        HStack {
            AppIconView(icon: identity.icon)
                .frame(height: 32)
                .opacity(model.iconOpacity)
                .overlay(alignment: .center) {
                    if let overlayAction {
                        Button {
                            perform(overlayAction)
                        } label: {
                            Image(systemSymbol: overlayAction.systemSymbol)
                                .foregroundStyle(overlayAction.tint)
                        }
                        .buttonBorderShape(.circle)
                        .buttonStyle(.plain)
                        .imageScale(.large)
                    }
                }
                .fixedSize()
                .onTapGesture {
                    if let tapAction {
                        perform(tapAction)
                    }
                }

            VStack(alignment: .leading) {
                HStack(spacing: 5) {
                    if let indicator = model.captureIndicator {
                        Circle()
                            .fill(indicator.color)
                            .frame(width: 7, height: 7)
                            .popover(isPresented: $isShowingCaptureUnavailableReason, arrowEdge: .trailing) {
                                Text(indicator.reason?.title ?? "")
                                    .font(.caption)
                                    .padding(8)
                            }
                            .onHover { isHovering in
                                isShowingCaptureUnavailableReason = isHovering && indicator.reason != nil
                            }
                    }

                    Text(identity.localizedName)
                        .lineLimit(1)
                        .foregroundStyle(model.isWhitelisted ? AnyShapeStyle(.primary) : AnyShapeStyle(.placeholder))
                }

                CountSummary(
                    items: countSummaryItems
                )
                .foregroundStyle(model.isWhitelisted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.placeholder))
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
                AppInfoView(app: model.app, identity: identity)
            }
        }
    }

    private var countSummaryItems: [CountSummary.Item] {
        var items: [CountSummary.Item] = [
            .init(value: model.app.sessionCount, systemSymbol: .film),
            .init(value: model.app.screenshotCount, systemSymbol: .photo),
        ]

        if model.app.sizeBytes > 0 {
            items.append(
                .init(
                    text: model.app.sizeBytes.formatted(.byteCount(style: .file)),
                    systemSymbol: .externaldrive,
                    isMonospaced: true
                )
            )
        }

        if let captureInterval = model.captureInterval {
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

    private var overlayAction: CaptureAction? {
        guard model.isRunning else {
            return nil
        }

        return switch model.captureState {
        case .auto(isRunning: _, isEnabled: false):
            .resumeAuto
        case .manual(isRunning: _, isCapturing: true):
            .stopCapture
        default:
            nil
        }
    }

    private var tapAction: CaptureAction? {
        guard model.isRunning else {
            return nil
        }

        return switch model.captureState {
        case .auto(isRunning: _, isEnabled: true):
            .pauseAuto
        case .manual(isRunning: _, isCapturing: false):
            .startCapture
        default:
            nil
        }
    }

    private func perform(_ action: CaptureAction) {
        switch action {
        case .pauseAuto:
            actions.setAutoCaptureEnabled(false)
        case .resumeAuto:
            actions.setAutoCaptureEnabled(true)
        case .startCapture:
            actions.startCapture()
        case .stopCapture:
            actions.stopCapture()
        }
    }

    struct Model {
        let app: AppCaptureSummary
        let captureState: CaptureState
        let captureInterval: TimeInterval?

        init(
            app: AppCaptureSummary,
            whitelistConfig: WhitelistedAppConfig?,
            isRunning: Bool,
            isCapturing: Bool,
            unavailableReason: CaptureUnavailableReason? = nil
        ) {
            self.app = app
            captureInterval = whitelistConfig?.captureInterval
            captureIndicator = if let unavailableReason {
                .unavailable(unavailableReason)
            } else if isCapturing {
                .capturing
            } else {
                nil
            }

            guard let whitelistConfig else {
                captureState = .stale(isRunning: isRunning)
                return
            }

            captureState = switch whitelistConfig.captureMode {
            case .auto:
                .auto(isRunning: isRunning, isEnabled: whitelistConfig.isEnabled)
            case .manual:
                .manual(isRunning: isRunning, isCapturing: isCapturing)
            }
        }

        let captureIndicator: CaptureIndicator?

        var isWhitelisted: Bool {
            if case .stale = captureState {
                return false
            }
            return true
        }

        var isRunning: Bool {
            switch captureState {
            case let .stale(isRunning),
                 let .auto(isRunning, _),
                 let .manual(isRunning, _):
                isRunning
            }
        }

        var iconOpacity: CGFloat {
            guard isRunning else {
                return 0.45
            }

            return switch captureState {
            case .auto(isRunning: _, isEnabled: false),
                 .manual(isRunning: _, isCapturing: true):
                0.45
            default:
                1
            }
        }
    }

    enum CaptureState {
        case stale(isRunning: Bool)
        case auto(isRunning: Bool, isEnabled: Bool)
        case manual(isRunning: Bool, isCapturing: Bool)
    }

    enum CaptureIndicator: Equatable {
        case capturing
        case unavailable(CaptureUnavailableReason)

        var color: Color {
            switch self {
            case .capturing:
                .red
            case .unavailable:
                .yellow
            }
        }

        var reason: CaptureUnavailableReason? {
            switch self {
            case .capturing:
                nil
            case let .unavailable(reason):
                reason
            }
        }
    }

    struct Actions {
        var setAutoCaptureEnabled: (Bool) -> Void = { _ in }
        var startCapture: () -> Void = {}
        var stopCapture: () -> Void = {}
    }

    private enum CaptureAction {
        case pauseAuto
        case resumeAuto
        case startCapture
        case stopCapture

        var systemSymbol: SFSymbol {
            switch self {
            case .pauseAuto:
                .pauseCircle
            case .resumeAuto:
                .playCircle
            case .startCapture:
                .recordCircle
            case .stopCapture:
                .stopCircle
            }
        }

        var tint: Color {
            switch self {
            case .stopCapture:
                .red
            case .pauseAuto, .resumeAuto, .startCapture:
                .primary
            }
        }
    }
}

#Preview {
    AppSidebarRow(
        model: .init(
            app: AppCaptureSummary(
                bundleIdentifier: "com.apple.TextEdit",
                displayName: "TextEdit",
                sessionCount: 3,
                screenshotCount: 128,
                lastCapturedAt: .now
            ),
            whitelistConfig: .init(
                bundleIdentifier: "com.apple.TextEdit",
                displayName: "TextEdit",
                captureInterval: 5,
                isEnabled: true
            ),
            isRunning: true,
            isCapturing: false
        )
    )
    .padding()
    .frame(width: 260)
}
