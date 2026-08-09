import AppKit
@preconcurrency import AVFoundation
import ComposableArchitecture
import CoreVideo
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Codec / container → AVFoundation mapping

extension TimelapseVideoCodec {
    nonisolated var avCodec: AVVideoCodecType {
        switch self {
        case .h264:
            .h264
        case .hevc:
            .hevc
        }
    }
}

extension TimelapseVideoContainer {
    var contentType: UTType {
        switch self {
        case .mp4:
            .mpeg4Movie
        case .mov:
            .quickTimeMovie
        }
    }

    nonisolated var avFileType: AVFileType {
        switch self {
        case .mp4:
            .mp4
        case .mov:
            .mov
        }
    }
}

// MARK: - Clients

/// Encodes screenshots into a timelapse video, reporting frame progress as it goes.
nonisolated struct TimelapseExportClient {
    var export: @Sendable (_ request: TimelapseExportRequest) -> AsyncThrowingStream<TimelapseExportProgress, Error>
}

/// Presents the export save panel — with an accessory view for format and frame rate — and
/// returns the chosen destination plus options. `frameHashes` are the perceptual hashes of the
/// frames being exported (order matters), used to estimate length and to power the trim and
/// near-duplicate options live in the accessory.
nonisolated struct ExportPanelClient {
    var present: @Sendable (_ suggestedName: String, _ frameHashes: [UInt64]) async -> ExportSelection?
}

// MARK: - Live values

extension TimelapseExportClient: DependencyKey {
    static let liveValue = Self { request in
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await TimelapseEncoder.encode(request) { progress in
                        continuation.yield(progress)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let testValue = Self { _ in
        AsyncThrowingStream {
            reportIssue("TimelapseExportClient.export is unimplemented")
            $0.finish()
        }
    }
}

extension ExportPanelClient: DependencyKey {
    static let liveValue = Self { suggestedName, frameHashes in
        await present(suggestedName: suggestedName, frameHashes: frameHashes)
    }

    @MainActor
    private static func present(suggestedName: String, frameHashes: [UInt64]) async -> ExportSelection? {
        let panel = NSSavePanel()
        let model = ExportAccessoryModel(frameHashes: frameHashes)

        panel.allowedContentTypes = [model.container.contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let accessory = NSHostingView(rootView: AnyView(EmptyView()))
        accessory.rootView = AnyView(
            ExportOptionsAccessory(
                model: model,
                onContainerChange: { [weak panel] container in
                    panel?.allowedContentTypes = [container.contentType]
                },
                onContentSizeChange: { [weak accessory] size in
                    // The save panel sizes itself from the accessory's frame, so grow/shrink the
                    // hosting view as the SwiftUI content changes height (e.g. expanding the
                    // Advanced disclosure or the trim fields) instead of clipping it.
                    guard let accessory else { return }
                    let newSize = NSSize(width: size.width, height: size.height)
                    if accessory.frame.size != newSize {
                        accessory.setFrameSize(newSize)
                    }
                }
            )
        )
        accessory.setFrameSize(accessory.fittingSize)
        panel.accessoryView = accessory

        // Present as a window-attached sheet (slides from the title bar, dims the window),
        // matching SwiftUI's file exporter. Fall back to a modal panel only if there's no
        // window to host the sheet.
        let response: NSApplication.ModalResponse
        if let window = hostWindow() {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }

        guard response == .OK, let url = panel.url else { return nil }
        return ExportSelection(destinationURL: url, options: model.options)
    }

    @MainActor
    private static func hostWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    static let testValue = Self { _, _ in
        reportIssue("ExportPanelClient.present is unimplemented")
        return nil
    }
}

extension DependencyValues {
    var timelapseExportClient: TimelapseExportClient {
        get { self[TimelapseExportClient.self] }
        set { self[TimelapseExportClient.self] = newValue }
    }

    var exportPanelClient: ExportPanelClient {
        get { self[ExportPanelClient.self] }
        set { self[ExportPanelClient.self] = newValue }
    }
}
