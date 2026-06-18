import CoreGraphics
import Foundation

nonisolated struct WhitelistedAppConfig: Equatable, Identifiable {
    var id: String {
        bundleIdentifier
    }

    var bundleIdentifier: String
    var displayName: String
    var captureInterval: TimeInterval
    var isEnabled: Bool

    var sanitizedInterval: Duration {
        .seconds(max(1, captureInterval))
    }
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

nonisolated struct CapturableWindow: Equatable, Identifiable {
    var id: Int {
        systemWindowID
    }

    var systemWindowID: Int
    var title: String?
    var frame: CGRect
    var layer: Int
    var isOnScreen: Bool

    var shouldCapture: Bool {
        isOnScreen
            && layer == 0
            && frame.width >= 80
            && frame.height >= 80
            && !frame.isEmpty
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

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
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
            "Screen Recording permission is required before Elapsed Record can capture windows."
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
