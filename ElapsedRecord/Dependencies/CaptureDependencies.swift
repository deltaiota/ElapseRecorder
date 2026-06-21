@preconcurrency import AppKit
import Chronicle
import ComposableArchitecture
import CoreGraphics
import Defaults
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

nonisolated extension CaptureImageFormat: Defaults.Serializable {}

nonisolated extension Defaults.Keys {
    static let captureImageFormat = Key<CaptureImageFormat>("captureImageFormat", default: .heic)
    static let captureHEICQuality = Key<Double>("captureHEICQuality", default: 0.82)
    static let thumbnailMaximumPixelSize = Key<Int>("thumbnailMaximumPixelSize", default: 1024)
    static let whitelistedAppConfigsData = Key<Data>("whitelistedAppConfigsData", default: Data())
}

nonisolated struct DateClient {
    var now: @Sendable () -> Date
}

nonisolated struct IDGeneratorClient {
    var uuid: @Sendable () -> UUID
}

nonisolated struct CapturePreferencesClient {
    var encodingOptions: @Sendable () -> CaptureEncodingOptions
    var thumbnailMaximumPixelSize: @Sendable () -> Int
}

nonisolated struct WhitelistConfigurationClient {
    var load: @Sendable () async throws -> [WhitelistedAppConfig]
    var save: @Sendable (_ configs: [WhitelistedAppConfig]) async throws -> Void
}

nonisolated struct WorkspaceClient {
    var runningApplications: @Sendable () async -> [RunningApplication]
    var events: @Sendable () -> AsyncStream<WorkspaceEvent>
}

nonisolated struct CapturePermissionClient {
    var status: @Sendable () async -> CapturePermissionStatus
    var request: @Sendable () async -> CapturePermissionStatus
}

nonisolated struct ScreenCaptureClient {
    var windows: @Sendable (_ application: RunningApplication) async throws -> [CapturableWindow]
    var capture: @Sendable (_ windowID: Int) async throws -> CapturedImage
}

nonisolated struct ImageEncodingClient {
    var encode: @Sendable (_ image: CapturedImage, _ options: CaptureEncodingOptions) async throws -> Data
}

nonisolated struct FileStorageClient {
    var captureRoot: @Sendable () throws -> URL
    var screenshotURL: @Sendable (_ session: CaptureSession, _ window: MonitoredWindow, _ capturedAt: Date, _ format: CaptureImageFormat) throws -> URL
    var write: @Sendable (_ data: Data, _ url: URL) async throws -> Int
    var deleteSessionCaptures: @Sendable (_ bundleIdentifier: String, _ sessionID: UUID) async throws -> Void
    var deleteAppCaptures: @Sendable (_ bundleIdentifier: String) async throws -> Void
}

nonisolated struct PersistenceClient {
    var openSession: @Sendable (_ session: CaptureSession) async throws -> Void
    var closeSession: @Sendable (_ sessionID: UUID, _ endedAt: Date) async throws -> Void
    var closeOpenSessions: @Sendable (_ endedAt: Date) async throws -> Int
    var deleteSession: @Sendable (_ sessionID: UUID) async throws -> Void
    var deleteApp: @Sendable (_ bundleIdentifier: String) async throws -> Void
    var upsertWindow: @Sendable (_ window: MonitoredWindow) async throws -> Void
    var recordScreenshot: @Sendable (_ record: ScreenshotRecord) async throws -> Void
    var recordCaptureUnavailable: @Sendable (_ record: CaptureUnavailableRecord) async throws -> Void
    var apps: @Sendable () async throws -> [AppCaptureSummary]
    var sessions: @Sendable (_ bundleIdentifier: String) async throws -> [CaptureSessionSummary]
    var windows: @Sendable (_ sessionID: UUID) async throws -> [WindowCaptureSummary]
    var screenshotsForSession: @Sendable (_ sessionID: UUID) async throws -> [ScreenshotRecord]
    var screenshotsForWindow: @Sendable (_ windowID: UUID) async throws -> [ScreenshotRecord]
    var screenshotsForApp: @Sendable (_ bundleIdentifier: String) async throws -> [ScreenshotRecord]
    var timelineForSession: @Sendable (_ sessionID: UUID) async throws -> [CaptureTimelineEntry]
    var timelineForWindow: @Sendable (_ sessionID: UUID, _ windowID: UUID) async throws -> [CaptureTimelineEntry]
    var timelineForApp: @Sendable (_ bundleIdentifier: String) async throws -> [CaptureTimelineEntry]
}

nonisolated struct ThumbnailClient {
    var thumbnail: @Sendable (_ url: URL, _ maximumPixelSize: Int) async throws -> CGImage
}

nonisolated struct ImageLoadingClient {
    var fullSizeImage: @Sendable (_ url: URL) async throws -> CGImage
}

nonisolated struct FileRevealClient {
    var reveal: @Sendable (_ url: URL) async -> Void
}

nonisolated struct LoggingClient {
    var log: @Sendable (_ level: LogLevel, _ message: String, _ metadata: [String: LogMetadataValue]) -> Void
}

extension WorkspaceClient: DependencyKey {
    static let liveValue = Self(
        runningApplications: {
            NSWorkspace.shared.runningApplications.compactMap(RunningApplication.init(application:))
        },
        events: {
            AsyncStream { continuation in
                let center = NSWorkspace.shared.notificationCenter
                let launched = center.addObserver(
                    forName: NSWorkspace.didLaunchApplicationNotification,
                    object: nil,
                    queue: .main
                ) { notification in
                    guard let app = notification.runningApplication else { return }
                    continuation.yield(.launched(app))
                }
                let terminated = center.addObserver(
                    forName: NSWorkspace.didTerminateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { notification in
                    guard let app = notification.runningApplication else { return }
                    continuation.yield(.terminated(app))
                }
                let activated = center.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { notification in
                    guard let app = notification.runningApplication else { return }
                    continuation.yield(.activated(app))
                }
                continuation.onTermination = { _ in
                    center.removeObserver(launched)
                    center.removeObserver(terminated)
                    center.removeObserver(activated)
                }
            }
        }
    )
}

extension DateClient: DependencyKey {
    static let liveValue = Self(now: Date.init)
}

extension IDGeneratorClient: DependencyKey {
    static let liveValue = Self(uuid: UUID.init)
}

extension CapturePreferencesClient: DependencyKey {
    static let liveValue = Self(
        encodingOptions: {
            CaptureEncodingOptions(
                format: Defaults[.captureImageFormat],
                heicQuality: Defaults[.captureHEICQuality]
            )
        },
        thumbnailMaximumPixelSize: {
            Defaults[.thumbnailMaximumPixelSize]
        }
    )
}

extension WhitelistConfigurationClient: DependencyKey {
    static let liveValue = Self(
        load: {
            let data = Defaults[.whitelistedAppConfigsData]
            guard !data.isEmpty else { return [] }
            return try JSONDecoder().decode([WhitelistedAppConfig].self, from: data)
        },
        save: { configs in
            Defaults[.whitelistedAppConfigsData] = try JSONEncoder().encode(configs)
        }
    )
}

extension CapturePermissionClient: DependencyKey {
    static let liveValue = Self(
        status: {
            CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
        },
        request: {
            if CGPreflightScreenCaptureAccess() {
                return .authorized
            }
            return CGRequestScreenCaptureAccess() ? .authorized : .denied
        }
    )
}

extension ScreenCaptureClient: DependencyKey {
    static let liveValue = Self(
        windows: { application in
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return content.windows
                .filter { window in
                    window.owningApplication?.bundleIdentifier == application.bundleIdentifier
                        && window.owningApplication?.processID == application.processIdentifier
                }
                .map(CapturableWindow.init(window:))
        },
        capture: { windowID in
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { Int($0.windowID) == windowID }) else {
                throw CaptureEngineError.windowCaptureFailed(systemWindowID: windowID)
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let info = SCShareableContent.info(for: filter)
            let scale = CGFloat(info.pointPixelScale)
            configuration.width = max(1, Int((info.contentRect.width * scale).rounded(.up)))
            configuration.height = max(1, Int((info.contentRect.height * scale).rounded(.up)))
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CapturedImage(cgImage: image)
        }
    )
}

extension ImageEncodingClient: DependencyKey {
    static let liveValue = Self { image, options in
        let data = NSMutableData()
        let type: UTType = options.format == .heic ? .heic : .png

        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CaptureEngineError.windowCaptureFailed(systemWindowID: -1)
        }

        var properties: [CFString: Any] = [:]
        if options.format == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = options.heicQuality
        }

        CGImageDestinationAddImage(destination, image.cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureEngineError.windowCaptureFailed(systemWindowID: -1)
        }

        return data as Data
    }
}

extension FileStorageClient: DependencyKey {
    static let liveValue = Self(
        captureRoot: FileStoragePaths.captureRoot,
        screenshotURL: { session, window, capturedAt, format in
            let timestamp = CaptureFilenameFormatter.string(from: capturedAt)
            let directory = try FileStoragePaths.sessionDirectory(
                bundleIdentifier: session.bundleIdentifier,
                sessionID: session.id,
                create: true
            )
            .appending(path: "window-\(window.displayNumber)", directoryHint: .isDirectory)

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            return directory.appending(path: "\(timestamp).\(format.fileExtension)")
        },
        write: { data, url in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                return values.fileSize ?? data.count
            } catch {
                throw CaptureEngineError.fileWriteFailed(url)
            }
        },
        deleteSessionCaptures: { bundleIdentifier, sessionID in
            let directory = try FileStoragePaths.sessionDirectory(
                bundleIdentifier: bundleIdentifier,
                sessionID: sessionID,
                create: false
            )
            guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
            try FileManager.default.removeItem(at: directory)
        },
        deleteAppCaptures: { bundleIdentifier in
            let directory = try FileStoragePaths.appDirectory(
                bundleIdentifier: bundleIdentifier,
                create: false
            )
            guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
            try FileManager.default.removeItem(at: directory)
        }
    )
}

nonisolated enum FileStoragePaths {
    static func captureRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appending(path: "ElapsedRecord/Captures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func sessionDirectory(
        bundleIdentifier: String,
        sessionID: UUID,
        create: Bool
    ) throws -> URL {
        let directory = try appDirectory(bundleIdentifier: bundleIdentifier, create: create)
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)

        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }

    static func appDirectory(
        bundleIdentifier: String,
        create: Bool
    ) throws -> URL {
        let directory = try captureRoot()
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)

        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }
}

extension PersistenceClient: DependencyKey {
    static let liveValue = Self.live()
}

extension ThumbnailClient: DependencyKey {
    static let liveValue = Self { url, maximumPixelSize in
        try await Task.detached(priority: .high) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw CaptureEngineError.fileWriteFailed(url)
            }

            let clampedMaximumPixelSize = ImageSourceSizing.clampedMaximumPixelSize(
                for: source,
                requested: maximumPixelSize
            )
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: clampedMaximumPixelSize,
            ] as CFDictionary

            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                throw CaptureEngineError.fileWriteFailed(url)
            }
            return thumbnail
        }.value
    }
}

nonisolated enum ImageSourceSizing {
    static func clampedMaximumPixelSize(for source: CGImageSource, requested: Int) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return max(1, requested)
        }

        return max(1, min(requested, max(width, height)))
    }
}

extension ImageLoadingClient: DependencyKey {
    static let liveValue = Self { url in
        try await Task.detached(priority: .high) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw CaptureEngineError.fileWriteFailed(url)
            }

            return image
        }.value
    }
}

extension FileRevealClient: DependencyKey {
    static let liveValue = Self { url in
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

extension LoggingClient: DependencyKey {
    static let liveValue = Self { level, message, metadata in
        Logger.shared.log(message, level: level, tags: [.capture], metadata: metadata)
    }
}

extension DependencyValues {
    var dateClient: DateClient {
        get { self[DateClient.self] }
        set { self[DateClient.self] = newValue }
    }

    var idGeneratorClient: IDGeneratorClient {
        get { self[IDGeneratorClient.self] }
        set { self[IDGeneratorClient.self] = newValue }
    }

    var capturePreferencesClient: CapturePreferencesClient {
        get { self[CapturePreferencesClient.self] }
        set { self[CapturePreferencesClient.self] = newValue }
    }

    var whitelistConfigurationClient: WhitelistConfigurationClient {
        get { self[WhitelistConfigurationClient.self] }
        set { self[WhitelistConfigurationClient.self] = newValue }
    }

    var workspaceClient: WorkspaceClient {
        get { self[WorkspaceClient.self] }
        set { self[WorkspaceClient.self] = newValue }
    }

    var capturePermissionClient: CapturePermissionClient {
        get { self[CapturePermissionClient.self] }
        set { self[CapturePermissionClient.self] = newValue }
    }

    var screenCaptureClient: ScreenCaptureClient {
        get { self[ScreenCaptureClient.self] }
        set { self[ScreenCaptureClient.self] = newValue }
    }

    var imageEncodingClient: ImageEncodingClient {
        get { self[ImageEncodingClient.self] }
        set { self[ImageEncodingClient.self] = newValue }
    }

    var fileStorageClient: FileStorageClient {
        get { self[FileStorageClient.self] }
        set { self[FileStorageClient.self] = newValue }
    }

    var persistenceClient: PersistenceClient {
        get { self[PersistenceClient.self] }
        set { self[PersistenceClient.self] = newValue }
    }

    var thumbnailClient: ThumbnailClient {
        get { self[ThumbnailClient.self] }
        set { self[ThumbnailClient.self] = newValue }
    }

    var imageLoadingClient: ImageLoadingClient {
        get { self[ImageLoadingClient.self] }
        set { self[ImageLoadingClient.self] = newValue }
    }

    var fileRevealClient: FileRevealClient {
        get { self[FileRevealClient.self] }
        set { self[FileRevealClient.self] = newValue }
    }

    var loggingClient: LoggingClient {
        get { self[LoggingClient.self] }
        set { self[LoggingClient.self] = newValue }
    }
}

nonisolated extension Notification {
    var runningApplication: RunningApplication? {
        (userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            .flatMap(RunningApplication.init(application:))
    }
}

nonisolated extension RunningApplication {
    init?(application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier else { return nil }

        self.init(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }
}

nonisolated extension CapturableWindow {
    init(window: SCWindow) {
        self.init(
            systemWindowID: Int(window.windowID),
            title: window.title,
            frame: window.frame,
            layer: window.windowLayer,
            isOnScreen: window.isOnScreen
        )
    }
}

nonisolated extension PersistenceClient {
    static let unimplemented = Self(
        openSession: { _ in reportIssue("PersistenceClient.openSession is unimplemented") },
        closeSession: { _, _ in reportIssue("PersistenceClient.closeSession is unimplemented") },
        closeOpenSessions: { _ in
            reportIssue("PersistenceClient.closeOpenSessions is unimplemented")
            return 0
        },
        deleteSession: { _ in reportIssue("PersistenceClient.deleteSession is unimplemented") },
        deleteApp: { _ in reportIssue("PersistenceClient.deleteApp is unimplemented") },
        upsertWindow: { _ in reportIssue("PersistenceClient.upsertWindow is unimplemented") },
        recordScreenshot: { _ in reportIssue("PersistenceClient.recordScreenshot is unimplemented") },
        recordCaptureUnavailable: { _ in reportIssue("PersistenceClient.recordCaptureUnavailable is unimplemented") },
        apps: {
            reportIssue("PersistenceClient.apps is unimplemented")
            return []
        },
        sessions: { _ in
            reportIssue("PersistenceClient.sessions is unimplemented")
            return []
        },
        windows: { _ in
            reportIssue("PersistenceClient.windows is unimplemented")
            return []
        },
        screenshotsForSession: { _ in
            reportIssue("PersistenceClient.screenshotsForSession is unimplemented")
            return []
        },
        screenshotsForWindow: { _ in
            reportIssue("PersistenceClient.screenshotsForWindow is unimplemented")
            return []
        },
        screenshotsForApp: { _ in
            reportIssue("PersistenceClient.screenshotsForApp is unimplemented")
            return []
        },
        timelineForSession: { _ in
            reportIssue("PersistenceClient.timelineForSession is unimplemented")
            return []
        },
        timelineForWindow: { _, _ in
            reportIssue("PersistenceClient.timelineForWindow is unimplemented")
            return []
        },
        timelineForApp: { _ in
            reportIssue("PersistenceClient.timelineForApp is unimplemented")
            return []
        }
    )
}

nonisolated extension Tag {
    static let capture = Tag("Capture")
}

nonisolated enum CaptureFilenameFormatter {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
