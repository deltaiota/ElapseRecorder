import ComposableArchitecture
import Foundation

struct AppFeature: Reducer {
    struct State: Equatable {
        var captureEngine = CaptureEngineFeature.State()
        var viewer = ViewerFeature.State()
        var testBundleIdentifier = "com.apple.TextEdit"
        var testDisplayName = "TextEdit"
        var testIntervalSeconds = 5.0
        var isTestCaptureEnabled = false
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
    }

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
                return .merge(
                    .send(.captureEngine(.task)),
                    .send(.viewer(.task))
                )

            case .captureEngine(.screenshotRecorded):
                return .send(.viewer(.task))

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
                state.isTestCaptureEnabled = true
                return .send(.captureEngine(.whitelistUpdated([state.testWhitelistedAppConfig])))

            case .stopTestCaptureButtonTapped:
                state.isTestCaptureEnabled = false
                return .send(.captureEngine(.whitelistUpdated([])))

            case .refreshViewerButtonTapped:
                return .send(.viewer(.task))
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
