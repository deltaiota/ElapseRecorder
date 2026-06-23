import CoreGraphics
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

nonisolated enum CaptureMode: String, CaseIterable, Codable, Equatable {
    case auto
    case manual
}

nonisolated struct RunningApplication: Equatable, Identifiable {
    var id: String {
        bundleIdentifier
    }

    var bundleIdentifier: String
    var displayName: String
    var processIdentifier: pid_t
}

nonisolated struct CaptureSession: Equatable, Identifiable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var processIdentifier: pid_t
    var startedAt: Date
    var endedAt: Date?
}

nonisolated struct MonitoredWindow: Equatable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var systemWindowID: Int
    var displayNumber: Int
    var label: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
}

nonisolated struct ScreenshotRecord: Equatable, Identifiable {
    var id: UUID
    var windowID: UUID
    var sessionID: UUID
    var capturedAt: Date
    var fileURL: URL
    var fileSizeBytes: Int
}

nonisolated struct CaptureUnavailableRecord: Equatable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date
    var reason: CaptureUnavailableReason
}

nonisolated enum CaptureUnavailableReason: String, Codable, Equatable {
    case windowMinimized

    var title: String {
        switch self {
        case .windowMinimized:
            "Window hidden or unavailable for capture"
        }
    }
}

nonisolated enum CaptureTimelineEntry: Equatable, Identifiable {
    case screenshot(ScreenshotRecord)
    case unavailable(CaptureUnavailableRecord)

    var id: UUID {
        switch self {
        case let .screenshot(record):
            record.id
        case let .unavailable(record):
            record.id
        }
    }

    var occurredAt: Date {
        switch self {
        case let .screenshot(record):
            record.capturedAt
        case let .unavailable(record):
            record.startedAt
        }
    }
}

nonisolated struct CapturableWindow: Equatable, Identifiable {
    var id: Int {
        systemWindowID
    }

    var systemWindowID: Int
    var title: String?
    var frame: CGRect
    var layer: Int
    var isOnScreen: Bool
    /// True when the window is stowed on the Stage Manager strip. No public, sandbox-safe
    /// ScreenCaptureKit/CoreGraphics property distinguishes this — when stowed, the window
    /// stays on-screen but its reported frame shrinks to a small strip thumbnail while its
    /// real size (read via Accessibility) is unchanged. The live layer sets this by
    /// cross-checking the presented frame size against the app's real Accessibility window
    /// sizes; a mismatch means the window is being presented as a stowed proxy.
    var isStageManagerStowed: Bool = false

    var shouldCapture: Bool {
        isOnScreen
            && !isStageManagerStowed
            && layer == 0
            && frame.width >= 80
            && frame.height >= 80
            && !frame.isEmpty
    }

    static func capturableWindows(from windows: [Self]) -> [Self] {
        windows.filter { window in
            window.shouldCapture
                && !window.isLikelyAttachedSheetOrOverlay(in: windows)
        }
    }

    private func isLikelyAttachedSheetOrOverlay(in windows: [Self]) -> Bool {
        guard hasSystemPanelTitle else { return false }

        return windows.contains { other in
            other.systemWindowID != systemWindowID
                && other.shouldCapture
                && other.frame.area > frame.area
                && frame.intersection(other.frame).area >= frame.area * 0.85
        }
    }

    private var hasSystemPanelTitle: Bool {
        guard let title else { return true }

        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "open", "save", "save as", "export", "import", "print":
            return true
        default:
            return false
        }
    }
}

private nonisolated extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite, !isEmpty else { return 0 }
        return width * height
    }
}

nonisolated struct CapturedImage {
    var cgImage: CGImage
}

nonisolated enum CaptureImageFormat: String, CaseIterable, Codable, Equatable {
    case heic
    case png

    var fileExtension: String {
        switch self {
        case .heic:
            "heic"
        case .png:
            "png"
        }
    }
}

nonisolated struct CaptureEncodingOptions: Equatable {
    var format: CaptureImageFormat
    var heicQuality: Double

    static let defaultValue = Self(format: .heic, heicQuality: 0.82)
}

nonisolated enum CapturePermissionStatus: Equatable {
    case authorized
    case notDetermined
    case denied
}

nonisolated enum WorkspaceEvent: Equatable {
    case launched(RunningApplication)
    case terminated(RunningApplication)
    case activated(RunningApplication)
}

nonisolated struct AppCaptureSummary: Equatable, Identifiable {
    var id: String {
        bundleIdentifier
    }

    var bundleIdentifier: String
    var displayName: String
    var sessionCount: Int
    var screenshotCount: Int
    var lastCapturedAt: Date?
}

nonisolated struct CaptureSessionSummary: Equatable, Identifiable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var startedAt: Date
    var endedAt: Date?
    var windowCount: Int
    var screenshotCount: Int
}

nonisolated struct WindowCaptureSummary: Equatable, Identifiable {
    var id: UUID
    var displayNumber: Int
    var label: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var screenshotCount: Int
}

nonisolated enum CaptureEngineError: Error, Equatable, LocalizedError {
    case screenRecordingPermissionDenied
    case sessionNotFound(UUID)
    case windowCaptureFailed(systemWindowID: Int)
    case fileWriteFailed(URL)
    case persistenceUnavailable

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            "Screen Recording permission is required before Elapse Recorder can capture windows."
        case let .sessionNotFound(id):
            "Capture session \(id.uuidString) could not be found."
        case let .windowCaptureFailed(systemWindowID):
            "Window \(systemWindowID) could not be captured."
        case let .fileWriteFailed(url):
            "Screenshot could not be written to \(url.path)."
        case .persistenceUnavailable:
            "Capture metadata storage is unavailable."
        }
    }
}
