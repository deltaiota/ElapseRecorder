import Foundation

nonisolated struct WhitelistedAppConfig: Codable, Equatable, Identifiable {
    var id: String {
        bundleIdentifier
    }

    var bundleIdentifier: String
    var displayName: String
    var captureInterval: TimeInterval
    var captureMode: CaptureMode
    var isEnabled: Bool

    init(
        bundleIdentifier: String,
        displayName: String,
        captureInterval: TimeInterval,
        captureMode: CaptureMode = .auto,
        isEnabled: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.captureInterval = captureInterval
        self.captureMode = captureMode
        self.isEnabled = isEnabled
    }

    var sanitizedInterval: Duration {
        .seconds(max(1, captureInterval))
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case displayName
        case captureInterval
        case captureMode
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        displayName = try container.decode(String.self, forKey: .displayName)
        captureInterval = try container.decode(TimeInterval.self, forKey: .captureInterval)
        captureMode = try container.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .auto
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }
}
