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

    static let testValue = Self(now: { Date(timeIntervalSince1970: 0) })
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
        segmentHEVCQuality: { Defaults[.segmentHEVCQuality] },
        thumbnailMaximumPixelSize: {
            Defaults[.thumbnailMaximumPixelSize]
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
        segmentHEVCQuality: { 0.65 },
        thumbnailMaximumPixelSize: { 1024 },
        retentionPolicy: { .none }
    )
}

extension PerceptualHashClient: DependencyKey {
    static let liveValue = Self { image in
        differenceHash(image.cgImage)
    }

    /// The hash is a pure, deterministic function of the image, so tests can use the real
    /// implementation. Tests that need controlled Hamming distances override `hash` directly.
    static let testValue = Self { image in
        differenceHash(image.cgImage)
    }

    /// dHash: downscale to 9x8 grayscale and, for each row, emit a bit per adjacent-pixel
    /// comparison (left brighter than right), yielding 8×8 = 64 bits. Robust to small changes
    /// and cheap to compute.
    private nonisolated static func differenceHash(_ image: CGImage) -> UInt64 {
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

nonisolated struct PresentedWindowGeometry: Equatable, Sendable {
    var systemWindowID: Int
    var size: CGSize
}

/// Avoids synchronous Accessibility IPC into the captured application on every capture tick.
/// A fresh inspection is only needed when the app's presented window set or geometry changes.
final nonisolated class AccessibilityWindowGeometryCache: @unchecked Sendable {
    private struct Snapshot {
        var presentedWindows: [PresentedWindowGeometry]
        var realSizes: [CGSize]

        func matches(_ windows: [PresentedWindowGeometry]) -> Bool {
            guard presentedWindows.count == windows.count else { return false }
            return zip(presentedWindows, windows).allSatisfy { cached, current in
                cached.systemWindowID == current.systemWindowID
                    && abs(cached.size.width - current.size.width) <= 2
                    && abs(cached.size.height - current.size.height) <= 2
            }
        }
    }

    private let snapshots = LockIsolated<[pid_t: Snapshot]>([:])

    func realWindowSizes(
        pid: pid_t,
        presentedWindows: [PresentedWindowGeometry],
        fetch: @Sendable () -> [CGSize]?
    ) -> [CGSize]? {
        let normalizedWindows = presentedWindows.sorted {
            $0.systemWindowID < $1.systemWindowID
        }
        if let snapshot = snapshots.withValue({ $0[pid] }),
           snapshot.matches(normalizedWindows)
        {
            return snapshot.realSizes
        }

        guard let realSizes = fetch() else { return nil }
        snapshots.withValue {
            $0[pid] = Snapshot(presentedWindows: normalizedWindows, realSizes: realSizes)
        }
        return realSizes
    }
}

/// Retains the `SCWindow` snapshot produced by enumeration long enough for the immediately
/// following screenshot. Re-enumerating all shareable desktop content for every individual
/// window doubled the expensive ScreenCaptureKit discovery work in each cycle.
private final nonisolated class ScreenCaptureWindowCache: @unchecked Sendable {
    private let windows = LockIsolated<[Int: SCWindow]>([:])

    func store(_ newWindows: [SCWindow]) {
        windows.withValue { cached in
            for window in newWindows {
                cached[Int(window.windowID)] = window
            }
        }
    }

    func window(id: Int) -> SCWindow? {
        windows.withValue { $0[id] }
    }
}

extension ScreenCaptureClient: DependencyKey {
    static let liveValue: Self = {
        let windowCache = ScreenCaptureWindowCache()
        let accessibilityGeometryCache = AccessibilityWindowGeometryCache()
        return Self(
            windows: { application in
                // Enumerate the windows ScreenCaptureKit considers on-screen. The domain
                // `shouldCapture` filter then drops minimized/hidden/off-Space windows
                // (isOnScreen == false) and Stage Manager-stowed windows (flagged below).
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                let applicationWindows = content.windows.filter { window in
                    window.owningApplication?.bundleIdentifier == application.bundleIdentifier
                        && window.owningApplication?.processID == application.processIdentifier
                }
                windowCache.store(applicationWindows)

                // Accessibility calls are synchronous IPC into the target process. Repeating
                // them every tick can stall latency-sensitive apps such as drawing software,
                // so reuse the real sizes while ScreenCaptureKit reports stable geometry.
                let axSizes: [CGSize]?
                if applicationWindows.isEmpty {
                    axSizes = nil
                } else {
                    let presentedWindows = applicationWindows.map {
                        PresentedWindowGeometry(
                            systemWindowID: Int($0.windowID),
                            size: $0.frame.size
                        )
                    }
                    axSizes = accessibilityGeometryCache.realWindowSizes(
                        pid: application.processIdentifier,
                        presentedWindows: presentedWindows,
                        fetch: {
                            AccessibilityWindowInspector.realWindowSizes(
                                pid: application.processIdentifier
                            )
                        }
                    )
                }

                return applicationWindows.map { window in
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
                let window: SCWindow
                if let cached = windowCache.window(id: windowID) {
                    window = cached
                } else {
                    // Defensive fallback for callers that did not enumerate first.
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: true
                    )
                    guard let discovered = content.windows.first(where: { Int($0.windowID) == windowID }) else {
                        throw CaptureEngineError.windowCaptureFailed(systemWindowID: windowID)
                    }
                    windowCache.store([discovered])
                    window = discovered
                }
                guard window.isOnScreen else {
                    throw CaptureEngineError.windowCaptureFailed(systemWindowID: windowID)
                }

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let info = SCShareableContent.info(for: filter)
                let scale = CGFloat(info.pointPixelScale)
                let nativeWidth = max(1, Int((info.contentRect.width * scale).rounded(.up)))
                let nativeHeight = max(1, Int((info.contentRect.height * scale).rounded(.up)))
                let size = CaptureResolution.cappedPixelSize(
                    width: nativeWidth,
                    height: nativeHeight,
                    maxDimension: Defaults[.captureMaxDimension]
                )
                configuration.width = size.width
                configuration.height = size.height
                configuration.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                return CapturedImage(cgImage: image)
            }
        )
    }()
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
