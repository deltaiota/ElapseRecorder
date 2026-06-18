import ComposableArchitecture
import Foundation

struct AppFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var captureEngine = CaptureEngineFeature.State()
        var viewer = ViewerFeature.State()
        var testBundleIdentifier = "com.apple.TextEdit"
        var testDisplayName = "TextEdit"
        var testIntervalSeconds = 5.0
        var isTestCaptureEnabled = false
        var whitelistError: String?
    }

    @CasePathable
    enum Action: Equatable {
        case task
        case captureEngine(CaptureEngineFeature.Action)
        case viewer(ViewerFeature.Action)
        case testBundleIdentifierChanged(String)
        case testDisplayNameChanged(String)
        case testIntervalSecondsChanged(Double)
        case startTestCaptureButtonTapped
        case stopTestCaptureButtonTapped
        case refreshViewerButtonTapped
        case savedWhitelistLoaded([WhitelistedAppConfig])
        case whitelistSaveFailed(String)
    }

    @Dependency(\.whitelistConfigurationClient) private var whitelistConfiguration

    var body: some Reducer<State, Action> {
        Scope(state: \.captureEngine, action: \.captureEngine) {
            CaptureEngineFeature()
        }
        Scope(state: \.viewer, action: \.viewer) {
            ViewerFeature()
        }
        Reduce { state, action in
            switch action {
            case .task:
                let whitelistConfiguration = whitelistConfiguration
                return .merge(
                    .send(.captureEngine(.task)),
                    .send(.viewer(.task)),
                    .run { send in
                        do {
                            try await send(.savedWhitelistLoaded(await whitelistConfiguration.load()))
                        } catch {
                            await send(.whitelistSaveFailed(error.localizedDescription))
                        }
                    }
                )

            case .captureEngine(.screenshotRecorded):
                return .send(.viewer(.refresh))

            case .captureEngine, .viewer:
                return .none

            case let .testBundleIdentifierChanged(bundleIdentifier):
                state.testBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                return .none

            case let .testDisplayNameChanged(displayName):
                state.testDisplayName = displayName
                return .none

            case let .testIntervalSecondsChanged(interval):
                state.testIntervalSeconds = min(3600, max(1, interval))
                return .none

            case .startTestCaptureButtonTapped:
                let configs = [state.testWhitelistedAppConfig]
                state.isTestCaptureEnabled = true
                let whitelistConfiguration = whitelistConfiguration
                return .merge(
                    .send(.captureEngine(.whitelistUpdated(configs))),
                    .run { send in
                        do {
                            try await whitelistConfiguration.save(configs)
                        } catch {
                            await send(.whitelistSaveFailed(error.localizedDescription))
                        }
                    }
                )

            case .stopTestCaptureButtonTapped:
                state.isTestCaptureEnabled = false
                let whitelistConfiguration = whitelistConfiguration
                return .merge(
                    .send(.captureEngine(.whitelistUpdated([]))),
                    .run { send in
                        do {
                            try await whitelistConfiguration.save([])
                        } catch {
                            await send(.whitelistSaveFailed(error.localizedDescription))
                        }
                    }
                )

            case .refreshViewerButtonTapped:
                return .send(.viewer(.refresh))

            case let .savedWhitelistLoaded(configs):
                if let config = configs.first {
                    state.testBundleIdentifier = config.bundleIdentifier
                    state.testDisplayName = config.displayName
                    state.testIntervalSeconds = config.captureInterval
                    state.isTestCaptureEnabled = config.isEnabled
                } else {
                    state.isTestCaptureEnabled = false
                }
                return .send(.captureEngine(.whitelistUpdated(configs)))

            case let .whitelistSaveFailed(message):
                state.whitelistError = message
                return .none
            }
        }
    }
}

extension AppFeature.State {
    var testWhitelistedAppConfig: WhitelistedAppConfig {
        WhitelistedAppConfig(
            bundleIdentifier: testBundleIdentifier,
            displayName: testDisplayName.isEmpty ? testBundleIdentifier : testDisplayName,
            captureInterval: testIntervalSeconds,
            isEnabled: true
        )
    }

    var canStartTestCapture: Bool {
        !testBundleIdentifier.isEmpty
    }
}
