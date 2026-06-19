import ComposableArchitecture
import Foundation

struct AppFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var captureEngine = CaptureEngineFeature.State()
        var viewer = ViewerFeature.State()
        var whitelistConfigs: [WhitelistedAppConfig] = []
        var draftBundleIdentifier = "com.apple.TextEdit"
        var draftDisplayName = "TextEdit"
        var draftIntervalSeconds = 5.0
        var whitelistError: String?
    }

    @CasePathable
    enum Action: Equatable {
        case task
        case captureEngine(CaptureEngineFeature.Action)
        case viewer(ViewerFeature.Action)
        case draftBundleIdentifierChanged(String)
        case draftDisplayNameChanged(String)
        case draftIntervalSecondsChanged(Double)
        case addDraftWhitelistButtonTapped
        case addRunningApplicationButtonTapped(String)
        case removeWhitelistButtonTapped(String)
        case whitelistEnabledChanged(String, Bool)
        case whitelistIntervalChanged(String, Double)
        case refreshRunningApplicationsButtonTapped
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

            case .captureEngine(.screenshotRecorded),
                 .captureEngine(.sessionOpened),
                 .captureEngine(.sessionClosed):
                return .send(.viewer(.refresh))

            case .captureEngine, .viewer:
                return .none

            case let .draftBundleIdentifierChanged(bundleIdentifier):
                state.draftBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                return .none

            case let .draftDisplayNameChanged(displayName):
                state.draftDisplayName = displayName
                return .none

            case let .draftIntervalSecondsChanged(interval):
                state.draftIntervalSeconds = interval.sanitizedCaptureInterval
                return .none

            case .addDraftWhitelistButtonTapped:
                guard state.canAddDraftWhitelist else { return .none }
                state.upsertWhitelistConfig(state.draftWhitelistedAppConfig)
                state.whitelistError = nil
                return persistWhitelist(state.whitelistConfigs)

            case let .addRunningApplicationButtonTapped(bundleIdentifier):
                guard let application = state.captureEngine.runningApplications[bundleIdentifier] else {
                    return .none
                }
                let existing = state.whitelistConfigs.first { $0.bundleIdentifier == bundleIdentifier }
                state.upsertWhitelistConfig(
                    WhitelistedAppConfig(
                        bundleIdentifier: application.bundleIdentifier,
                        displayName: existing?.displayName ?? application.displayName,
                        captureInterval: existing?.captureInterval ?? state.draftIntervalSeconds,
                        isEnabled: true
                    )
                )
                state.whitelistError = nil
                return persistWhitelist(state.whitelistConfigs)

            case let .removeWhitelistButtonTapped(bundleIdentifier):
                state.whitelistConfigs.removeAll { $0.bundleIdentifier == bundleIdentifier }
                state.whitelistError = nil
                return persistWhitelist(state.whitelistConfigs)

            case let .whitelistEnabledChanged(bundleIdentifier, isEnabled):
                state.updateWhitelistConfig(bundleIdentifier) {
                    $0.isEnabled = isEnabled
                }
                state.whitelistError = nil
                return persistWhitelist(state.whitelistConfigs)

            case let .whitelistIntervalChanged(bundleIdentifier, interval):
                state.updateWhitelistConfig(bundleIdentifier) {
                    $0.captureInterval = interval.sanitizedCaptureInterval
                }
                state.whitelistError = nil
                return persistWhitelist(state.whitelistConfigs)

            case .refreshRunningApplicationsButtonTapped:
                return .send(.captureEngine(.refreshRunningApplications))

            case .refreshViewerButtonTapped:
                return .send(.viewer(.refresh))

            case let .savedWhitelistLoaded(configs):
                state.setWhitelistConfigs(configs)
                if let config = state.whitelistConfigs.first {
                    state.draftBundleIdentifier = config.bundleIdentifier
                    state.draftDisplayName = config.displayName
                    state.draftIntervalSeconds = config.captureInterval
                }
                return .send(.captureEngine(.whitelistUpdated(state.whitelistConfigs)))

            case let .whitelistSaveFailed(message):
                state.whitelistError = message
                return .none
            }
        }
    }

    private func persistWhitelist(_ configs: [WhitelistedAppConfig]) -> Effect<Action> {
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
    }
}

extension AppFeature.State {
    var draftWhitelistedAppConfig: WhitelistedAppConfig {
        WhitelistedAppConfig(
            bundleIdentifier: draftBundleIdentifier,
            displayName: draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? draftBundleIdentifier
                : draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
            captureInterval: draftIntervalSeconds,
            isEnabled: true
        )
    }

    var canAddDraftWhitelist: Bool {
        !draftBundleIdentifier.isEmpty
    }

    var sortedWhitelistConfigs: [WhitelistedAppConfig] {
        whitelistConfigs.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    var runningApplicationsAvailableForWhitelist: [RunningApplication] {
        captureEngine.runningApplications.values
            .filter { application in
                !whitelistConfigs.contains { $0.bundleIdentifier == application.bundleIdentifier }
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    mutating func setWhitelistConfigs(_ configs: [WhitelistedAppConfig]) {
        whitelistConfigs = Self.normalizedWhitelistConfigs(configs)
    }

    mutating func upsertWhitelistConfig(_ config: WhitelistedAppConfig) {
        let normalized = Self.normalizedWhitelistConfigs([config])
        guard let config = normalized.first else { return }

        if let index = whitelistConfigs.firstIndex(where: { $0.bundleIdentifier == config.bundleIdentifier }) {
            whitelistConfigs[index] = config
        } else {
            whitelistConfigs.append(config)
        }
        setWhitelistConfigs(whitelistConfigs)
    }

    mutating func updateWhitelistConfig(
        _ bundleIdentifier: String,
        _ update: (inout WhitelistedAppConfig) -> Void
    ) {
        guard let index = whitelistConfigs.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }

        update(&whitelistConfigs[index])
        setWhitelistConfigs(whitelistConfigs)
    }

    private static func normalizedWhitelistConfigs(_ configs: [WhitelistedAppConfig]) -> [WhitelistedAppConfig] {
        var order: [String] = []
        var configsByBundleIdentifier: [String: WhitelistedAppConfig] = [:]

        for config in configs {
            let bundleIdentifier = config.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleIdentifier.isEmpty else { continue }

            if configsByBundleIdentifier[bundleIdentifier] == nil {
                order.append(bundleIdentifier)
            }

            configsByBundleIdentifier[bundleIdentifier] = WhitelistedAppConfig(
                bundleIdentifier: bundleIdentifier,
                displayName: config.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? bundleIdentifier
                    : config.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                captureInterval: config.captureInterval.sanitizedCaptureInterval,
                isEnabled: config.isEnabled
            )
        }

        return order.compactMap { configsByBundleIdentifier[$0] }
    }
}

extension TimeInterval {
    var sanitizedCaptureInterval: TimeInterval {
        min(3600, max(1, self))
    }
}
