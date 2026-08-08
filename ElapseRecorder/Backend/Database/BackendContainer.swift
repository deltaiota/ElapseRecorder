import Foundation

/// Owns the single live backend graph so recording, storage, and maintenance share one database
/// pool and one storage coordinator actor.
@MainActor
final class BackendContainer {
    let database: ElapseDatabase
    let persistence: PersistenceClient
    let storage: StorageCoordinatorClient
    let recording: RecordingServiceClient

    init(databaseURL: URL, legacyStoreURL: URL? = nil) throws {
        let database = try ElapseDatabase(url: databaseURL)
        if let legacyStoreURL {
            try LegacyStoreImporter.importIfNeeded(from: legacyStoreURL, into: database)
        }
        let persistence = PersistenceClient.live(database: database)
        let storage = StorageCoordinatorClient.live(
            configuration: .defaultValue,
            persistence: persistence,
            fileStorage: .liveValue,
            imageEncoder: .liveValue,
            segmentWriter: .liveValue,
            segmentQuality: CapturePreferencesClient.liveValue.segmentHEVCQuality,
            now: { Date() },
            makeID: { UUID() }
        )
        let recording = RecordingServiceClient.live(
            persistence: persistence,
            storage: storage,
            workspace: .liveValue,
            permission: .liveValue,
            screenCapture: .liveValue,
            date: .liveValue,
            ids: .liveValue,
            perceptualHash: .liveValue,
            preferences: .liveValue,
            logger: .liveValue
        )

        self.database = database
        self.persistence = persistence
        self.storage = storage
        self.recording = recording
    }
}
