@preconcurrency import AppKit
import ApplicationServices
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
    static let skipIdenticalFrames = Key<Bool>("skipIdenticalFrames", default: true)
    static let identicalFrameHammingThreshold = Key<Int>("identicalFrameHammingThreshold", default: 4)
    static let identicalFrameHeartbeatSeconds = Key<Int>("identicalFrameHeartbeatSeconds", default: 300)
    static let customCaptureRootPath = Key<String>("customCaptureRootPath", default: "")
    static let retentionMaxAgeEnabled = Key<Bool>("retentionMaxAgeEnabled", default: false)
    static let retentionMaxAgeDays = Key<Int>("retentionMaxAgeDays", default: 30)
    static let retentionMaxSizeEnabled = Key<Bool>("retentionMaxSizeEnabled", default: false)
    static let retentionMaxSizeMegabytes = Key<Int>("retentionMaxSizeMegabytes", default: 2048)
    static let retentionMaxCountEnabled = Key<Bool>("retentionMaxCountEnabled", default: false)
    static let retentionMaxScreenshotCount = Key<Int>("retentionMaxScreenshotCount", default: 10000)
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
    var deduplicationOptions: @Sendable () -> FrameDeduplicationOptions
    var retentionPolicy: @Sendable () -> RetentionPolicy
}

/// Computes a 64-bit difference hash (dHash) of a captured frame for near-duplicate detection.
nonisolated struct PerceptualHashClient {
    var hash: @Sendable (_ image: CapturedImage) -> UInt64
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
    /// All regular files under the capture root(s), used by the integrity sweep to find orphans.
    var captureFileURLs: @Sendable () async throws -> [URL]
    /// Of the given absolute paths, those that still exist on disk (root-agnostic existence
    /// check so records written under a previous capture location aren't wrongly pruned).
    var filterExistingPaths: @Sendable (_ paths: [String]) async -> Set<String>
    /// Deletes the given files (ignoring any that are already gone) and returns bytes reclaimed.
    var removeFiles: @Sendable (_ urls: [URL]) async throws -> Int
}

nonisolated struct PersistenceClient {
    var openSession: @Sendable (_ session: CaptureSession) async throws -> Void
    var closeSession: @Sendable (_ sessionID: UUID, _ endedAt: Date) async throws -> Void
    var closeOpenSessions: @Sendable (_ endedAt: Date) async throws -> Int
    var deleteSession: @Sendable (_ sessionID: UUID) async throws -> Void
    var deleteApp: @Sendable (_ bundleIdentifier: String) async throws -> Void
    var deleteScreenshots: @Sendable (_ ids: [UUID]) async throws -> Void
    var screenshotFileIndex: @Sendable () async throws -> [ScreenshotFileReference]
    var sessionsStartedBefore: @Sendable (_ cutoff: Date, _ bundleIdentifier: String?) async throws -> [CaptureSessionSummary]
    var screenshotPathsForSession: @Sendable (_ sessionID: UUID) async throws -> [String]
    var screenshotPathsForApp: @Sendable (_ bundleIdentifier: String) async throws -> [String]
    var endedSessionsOldestFirst: @Sendable () async throws -> [CaptureSessionSummary]
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
    var sessionTimeline: @Sendable (_ sessionID: UUID) async throws -> SessionTimeline
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
        },
        deduplicationOptions: {
            FrameDeduplicationOptions(
                isEnabled: Defaults[.skipIdenticalFrames],
                hammingThreshold: Defaults[.identicalFrameHammingThreshold],
                heartbeat: .seconds(Defaults[.identicalFrameHeartbeatSeconds])
            )
        },
        retentionPolicy: {
            RetentionPolicy(
                maxAge: Defaults[.retentionMaxAgeEnabled]
                    ? TimeInterval(max(1, Defaults[.retentionMaxAgeDays])) * 86400
                    : nil,
                maxTotalBytes: Defaults[.retentionMaxSizeEnabled]
                    ? max(1, Defaults[.retentionMaxSizeMegabytes]) * 1_000_000
                    : nil,
                maxScreenshotCount: Defaults[.retentionMaxCountEnabled]
                    ? max(1, Defaults[.retentionMaxScreenshotCount])
                    : nil
            )
        }
    )

    /// Test defaults: no retention limits so pruning is a no-op unless a test opts in.
    static let testValue = Self(
        encodingOptions: { .defaultValue },
        thumbnailMaximumPixelSize: { 1024 },
        deduplicationOptions: { .defaultValue },
        retentionPolicy: { .none }
    )
}

extension PerceptualHashClient: DependencyKey {
    static let liveValue = Self { image in
        differenceHash(image.cgImage)
    }

    /// The hash is a pure, deterministic function of the image, so tests can use the real
    /// implementation. Tests that need controlled Hamming distances override `hash` directly.
    static let testValue = liveValue

    /// dHash: downscale to 9x8 grayscale and, for each row, emit a bit per adjacent-pixel
    /// comparison (left brighter than right), yielding 8×8 = 64 bits. Robust to small changes
    /// and cheap to compute.
    private static func differenceHash(_ image: CGImage) -> UInt64 {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0 ..< height {
            for column in 0 ..< (width - 1) {
                let left = pixels[row * width + column]
                let right = pixels[row * width + column + 1]
                if left > right {
                    hash |= (1 << bit)
                }
                bit += 1
            }
        }
        return hash
    }
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
            // Enumerate the windows ScreenCaptureKit considers on-screen. The domain
            // `shouldCapture` filter then drops minimized/hidden/off-Space windows
            // (isOnScreen == false) and Stage Manager-stowed windows (flagged below).
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // A stowed window stays on-screen but is presented as a small strip thumbnail,
            // so no ScreenCaptureKit/CoreGraphics property reveals it. Accessibility still
            // reports each window's real size, so a presented frame that matches none of the
            // app's real Accessibility sizes is a stowed proxy. When Accessibility isn't
            // granted, axSizes is nil and capture proceeds (graceful degradation).
            let axSizes = AccessibilityWindowInspector.realWindowSizes(pid: application.processIdentifier)

            return content.windows
                .filter { window in
                    window.owningApplication?.bundleIdentifier == application.bundleIdentifier
                        && window.owningApplication?.processID == application.processIdentifier
                }
                .map { window in
                    var capturable = CapturableWindow(window: window)
                    if let axSizes {
                        capturable.isStageManagerStowed = !AccessibilityWindowInspector.size(
                            window.frame.size,
                            matchesAnyOf: axSizes
                        )
                    }
                    return capturable
                }
        },
        capture: { windowID in
            // Re-enumerate through the same on-screen gate used for detection so a window
            // that became minimized between ticks is refused here (the caller turns the
            // thrown error into a timeline placeholder) instead of producing a stale frame.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { Int($0.windowID) == windowID }),
                  window.isOnScreen
            else {
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
        },
        captureFileURLs: {
            FileStoragePaths.allCaptureFileURLs()
        },
        filterExistingPaths: { paths in
            var existing = Set<String>()
            for path in paths where FileManager.default.fileExists(atPath: path) {
                existing.insert(path)
            }
            return existing
        },
        removeFiles: { urls in
            var reclaimed = 0
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                do {
                    try FileManager.default.removeItem(at: url)
                    reclaimed += size
                } catch {
                    // Ignore files that are already gone; keep reclaiming the rest.
                    continue
                }
            }
            return reclaimed
        }
    )
}

/// Reads each window's real size from Accessibility so the capture engine can tell a
/// genuinely visible window from a Stage Manager-stowed proxy. Accessibility reports the
/// window's true geometry regardless of how Stage Manager scales its on-screen
/// presentation, which is the only public, sandbox-free signal that survives stowing.
nonisolated enum AccessibilityWindowInspector {
    /// Real sizes of the app's non-minimized windows, or `nil` when Accessibility hasn't
    /// been granted (the caller then captures normally instead of treating everything as
    /// unavailable). Triggers the system permission prompt the first time it's missing.
    static func realWindowSizes(pid: pid_t) -> [CGSize]? {
        guard AXIsProcessTrusted() else {
            requestAccessOnce()
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let axWindows = windowsValue as? [AXUIElement]
        else {
            return nil
        }

        return axWindows.compactMap { axWindow in
            if boolAttribute(axWindow, kAXMinimizedAttribute) == true { return nil }
            return sizeAttribute(axWindow)
        }
    }

    /// Whether a presented frame size matches one of the real Accessibility sizes within a
    /// small tolerance (rounding between the two coordinate sources).
    static func size(_ size: CGSize, matchesAnyOf realSizes: [CGSize]) -> Bool {
        let tolerance: CGFloat = 2
        return realSizes.contains { real in
            abs(real.width - size.width) <= tolerance && abs(real.height - size.height) <= tolerance
        }
    }

    private static let accessRequested = LockIsolated(false)

    private static func requestAccessOnce() {
        let shouldPrompt = accessRequested.withValue { requested -> Bool in
            defer { requested = true }
            return !requested
        }
        guard shouldPrompt else { return }

        DispatchQueue.main.async {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    private static func sizeAttribute(_ element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }

        var size = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? Bool
    }
}

nonisolated enum FileStoragePaths {
    /// The active capture root. Honors a user-chosen custom location (Defaults) for new
    /// captures; falls back to the default Application Support location.
    static func captureRoot() throws -> URL {
        if let custom = customCaptureRoot() {
            try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        return try defaultCaptureRoot()
    }

    static func defaultCaptureRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appending(path: "ElapseRecorder/Captures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The user-chosen capture root, or nil when using the default. Empty/blank means default.
    static func customCaptureRoot() -> URL? {
        let path = Defaults[.customCaptureRootPath].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Every regular file under the active capture root and (if different) the default root, so
    /// the integrity sweep can find orphan files even after the capture location has changed.
    static func allCaptureFileURLs() -> [URL] {
        var roots: [URL] = []
        if let active = try? captureRoot() { roots.append(active) }
        if let fallback = try? defaultCaptureRoot(), !roots.contains(fallback) { roots.append(fallback) }

        var urls: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isRegular { urls.append(url) }
            }
        }
        return urls
    }

    /// Deterministic on-disk location for the SwiftData store.
    ///
    /// The default store location (`default.store` in the bare Application Support directory)
    /// can fail to open in a signed, non-sandboxed build, so we pin the database to a stable
    /// app-owned subdirectory that we create ourselves.
    static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "ElapseRecorder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "ElapseRecorder.store", directoryHint: .notDirectory)
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

    /// Logging is a fire-and-forget diagnostic side effect, so tests get a silent no-op
    /// by default instead of having to override it everywhere a logged path is exercised.
    static let testValue = Self { _, _, _ in }
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

    var perceptualHashClient: PerceptualHashClient {
        get { self[PerceptualHashClient.self] }
        set { self[PerceptualHashClient.self] = newValue }
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
        deleteScreenshots: { _ in reportIssue("PersistenceClient.deleteScreenshots is unimplemented") },
        screenshotFileIndex: {
            reportIssue("PersistenceClient.screenshotFileIndex is unimplemented")
            return []
        },
        sessionsStartedBefore: { _, _ in
            reportIssue("PersistenceClient.sessionsStartedBefore is unimplemented")
            return []
        },
        screenshotPathsForSession: { _ in
            reportIssue("PersistenceClient.screenshotPathsForSession is unimplemented")
            return []
        },
        screenshotPathsForApp: { _ in
            reportIssue("PersistenceClient.screenshotPathsForApp is unimplemented")
            return []
        },
        endedSessionsOldestFirst: {
            reportIssue("PersistenceClient.endedSessionsOldestFirst is unimplemented")
            return []
        },
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
        },
        sessionTimeline: { _ in
            reportIssue("PersistenceClient.sessionTimeline is unimplemented")
            return SessionTimeline(sessionID: UUID(), startedAt: .distantPast, endedAt: nil, lanes: [], unavailableSpans: [])
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
