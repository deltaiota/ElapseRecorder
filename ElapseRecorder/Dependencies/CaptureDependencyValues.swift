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
