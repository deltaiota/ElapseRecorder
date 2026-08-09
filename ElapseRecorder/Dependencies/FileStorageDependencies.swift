@preconcurrency import AppKit
import ApplicationServices
import AVFoundation
import Chronicle
import ComposableArchitecture
import CoreGraphics
import Defaults
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

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
        spoolFrameURL: { handle, windowID, frameID, format in
            try FileStoragePaths.spoolFrameURL(handle: handle, windowID: windowID, frameID: frameID, format: format)
        },
        segmentAssetURLs: { handle, assetID in
            try FileStoragePaths.segmentAssetURLs(handle: handle, assetID: assetID)
        },
        publishSegment: { partialURL, finalURL in
            guard !FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)) else {
                throw StorageCoordinatorError.readyAssetAlreadyExists(finalURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
        },
        fileExists: { url in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        },
        fileSize: { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return values.fileSize ?? 0
        },
        availableCapacity: {
            let root = try FileStoragePaths.captureRoot()
            let values = try root.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            return values.volumeAvailableCapacityForImportantUsage
                ?? values.volumeAvailableCapacity.map(Int64.init)
                ?? 0
        },
        probeWritable: {
            let directory = try FileStoragePaths.captureRoot()
                .appending(path: ".health", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "\(UUID().uuidString).probe", directoryHint: .notDirectory)
            defer { try? FileManager.default.removeItem(at: url) }
            try Data([0]).write(to: url, options: [.atomic, .withoutOverwriting])
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
                    continue
                }
            }
            return reclaimed
        },
        removeFilesStrict: { urls in
            var reclaimed = 0
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                do {
                    try FileManager.default.removeItem(at: url)
                    reclaimed += size
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue
                }
            }
            return reclaimed
        }
    )

    static let testValue = Self(
        captureRoot: {
            reportIssue("FileStorageClient.captureRoot is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        screenshotURL: { _, _, _, _ in
            reportIssue("FileStorageClient.screenshotURL is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        write: { _, _ in
            reportIssue("FileStorageClient.write is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        deleteSessionCaptures: { _, _ in
            reportIssue("FileStorageClient.deleteSessionCaptures is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        deleteAppCaptures: { _ in
            reportIssue("FileStorageClient.deleteAppCaptures is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        spoolFrameURL: { _, _, _, _ in
            reportIssue("FileStorageClient.spoolFrameURL is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        segmentAssetURLs: { _, _ in
            reportIssue("FileStorageClient.segmentAssetURLs is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        publishSegment: { _, _ in
            reportIssue("FileStorageClient.publishSegment is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        fileExists: { _ in
            reportIssue("FileStorageClient.fileExists is unimplemented")
            return false
        },
        fileSize: { _ in
            reportIssue("FileStorageClient.fileSize is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        availableCapacity: {
            reportIssue("FileStorageClient.availableCapacity is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        probeWritable: {
            reportIssue("FileStorageClient.probeWritable is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        captureFileURLs: {
            reportIssue("FileStorageClient.captureFileURLs is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        filterExistingPaths: { _ in
            reportIssue("FileStorageClient.filterExistingPaths is unimplemented")
            return []
        },
        removeFiles: { _ in
            reportIssue("FileStorageClient.removeFiles is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        removeFilesStrict: { _ in
            reportIssue("FileStorageClient.removeFilesStrict is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
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

        let value = unsafeBitCast(ref, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
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

    /// Deterministic app-owned location for the GRDB database.
    static func legacyStoreURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "ElapseRecorder/ElapseRecorder.store", directoryHint: .notDirectory)
    }

    static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "ElapseRecorder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: CaptureDatabaseSchema.fileName, directoryHint: .notDirectory)
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

    static func spoolFrameURL(
        handle: RecordingSessionHandle,
        windowID: UUID,
        frameID: UUID,
        format: CaptureImageFormat
    ) throws -> URL {
        let directory = try sessionDirectory(
            bundleIdentifier: handle.bundleIdentifier,
            sessionID: handle.sessionID,
            create: true
        )
        .appending(path: "Spool", directoryHint: .isDirectory)
        .appending(path: windowID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(frameID.uuidString).\(format.fileExtension)", directoryHint: .notDirectory)
    }

    static func segmentAssetURLs(
        handle: RecordingSessionHandle,
        assetID: UUID
    ) throws -> (partial: URL, final: URL) {
        let directory = try sessionDirectory(
            bundleIdentifier: handle.bundleIdentifier,
            sessionID: handle.sessionID,
            create: true
        )
        .appending(path: "Media/Segments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = assetID.uuidString
        return (
            directory.appending(path: "\(stem).partial.mov", directoryHint: .notDirectory),
            directory.appending(path: "\(stem).mov", directoryHint: .notDirectory)
        )
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
