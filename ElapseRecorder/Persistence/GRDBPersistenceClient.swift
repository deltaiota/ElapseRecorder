import Foundation
import GRDB

final nonisolated class GRDBPersistenceStore: Sendable {
    let database: ElapseDatabase

    init(database: ElapseDatabase) {
        self.database = database
    }
}

nonisolated extension PersistenceClient {
    static func live(databaseURL: URL? = nil) -> Self {
        do {
            let url: URL
            if let databaseURL {
                url = databaseURL
            } else {
                url = try FileStoragePaths.databaseURL()
            }
            return try live(database: ElapseDatabase(url: url))
        } catch {
            return unavailable
        }
    }

    static func live(database: ElapseDatabase) -> Self {
        let store = GRDBPersistenceStore(database: database)
        return Self(
            openSession: store.openSession,
            closeSession: store.closeSession,
            closeOpenSessions: store.closeOpenSessions,
            deleteSession: store.deleteSession,
            deleteApp: store.deleteApp,
            deleteScreenshots: store.deleteScreenshots,
            screenshotFileIndex: store.screenshotFileIndex,
            sessionsStartedBefore: store.sessionsStarted,
            screenshotPathsForSession: store.screenshotPaths,
            screenshotPathsForApp: store.screenshotPaths,
            endedSessionsOldestFirst: store.endedSessionsOldestFirst,
            retentionSnapshot: store.retentionSnapshot,
            prepareSessionDeletion: store.prepareSessionDeletion,
            pendingSessionDeletions: store.pendingSessionDeletions,
            finalizeSessionDeletion: store.finalizeSessionDeletion,
            upsertWindow: store.upsertWindow,
            recordScreenshot: store.recordScreenshot,
            recordCaptureUnavailable: store.recordCaptureUnavailable,
            registerSpoolFrame: store.registerSpoolFrame,
            markSpoolFrameReady: store.markSpoolFrameReady,
            failSpoolFrame: store.failSpoolFrame,
            recoverSpoolFrames: store.recoverSpoolFrames,
            pendingSpoolFrames: store.pendingSpoolFrames,
            spoolByteCount: store.spoolByteCount,
            createSegmentJob: store.createSegmentJob,
            leaseSegmentJob: store.leaseSegmentJob,
            markSegmentJobPublished: store.markSegmentJobPublished,
            commitSegmentJob: store.commitSegmentJob,
            failSegmentJob: store.failSegmentJob,
            requeueSegmentJob: store.requeueSegmentJob,
            recoverSegmentJobs: store.recoverSegmentJobs,
            pendingSegmentCleanups: store.pendingSegmentCleanups,
            completeSegmentCleanup: store.completeSegmentCleanup,
            apps: store.apps,
            sessions: store.sessions,
            windows: store.windows,
            screenshotsForSession: store.screenshotsForSession,
            screenshotsForWindow: store.screenshotsForWindow,
            screenshotsForApp: store.screenshotsForApp,
            framePage: store.framePage,
            frameQuerySnapshot: store.frameQuerySnapshot,
            frameCount: store.frameCount,
            framesByID: store.framesByID,
            timelineForSession: store.timelineForSession,
            timelineForWindow: store.timelineForWindow,
            timelineForApp: store.timelineForApp,
            sessionTimeline: store.sessionTimeline
        )
    }

    static let unavailable = Self(
        openSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        closeSession: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        closeOpenSessions: { _ in throw CaptureEngineError.persistenceUnavailable },
        deleteSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        deleteApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        deleteScreenshots: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotFileIndex: { throw CaptureEngineError.persistenceUnavailable },
        sessionsStartedBefore: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotPathsForSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotPathsForApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        endedSessionsOldestFirst: { throw CaptureEngineError.persistenceUnavailable },
        retentionSnapshot: { throw CaptureEngineError.persistenceUnavailable },
        prepareSessionDeletion: { _ in throw CaptureEngineError.persistenceUnavailable },
        pendingSessionDeletions: { throw CaptureEngineError.persistenceUnavailable },
        finalizeSessionDeletion: { _ in throw CaptureEngineError.persistenceUnavailable },
        upsertWindow: { _ in throw CaptureEngineError.persistenceUnavailable },
        recordScreenshot: { _ in throw CaptureEngineError.persistenceUnavailable },
        recordCaptureUnavailable: { _ in throw CaptureEngineError.persistenceUnavailable },
        registerSpoolFrame: { _ in throw CaptureEngineError.persistenceUnavailable },
        markSpoolFrameReady: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        failSpoolFrame: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        recoverSpoolFrames: { _ in throw CaptureEngineError.persistenceUnavailable },
        pendingSpoolFrames: { _ in throw CaptureEngineError.persistenceUnavailable },
        spoolByteCount: { throw CaptureEngineError.persistenceUnavailable },
        createSegmentJob: { _ in throw CaptureEngineError.persistenceUnavailable },
        leaseSegmentJob: { _, _, _ in throw CaptureEngineError.persistenceUnavailable },
        markSegmentJobPublished: { _ in throw CaptureEngineError.persistenceUnavailable },
        commitSegmentJob: { _ in throw CaptureEngineError.persistenceUnavailable },
        failSegmentJob: { _, _, _, _, _ in throw CaptureEngineError.persistenceUnavailable },
        requeueSegmentJob: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        recoverSegmentJobs: { _ in throw CaptureEngineError.persistenceUnavailable },
        pendingSegmentCleanups: { throw CaptureEngineError.persistenceUnavailable },
        completeSegmentCleanup: { _ in throw CaptureEngineError.persistenceUnavailable },
        apps: { throw CaptureEngineError.persistenceUnavailable },
        sessions: { _ in throw CaptureEngineError.persistenceUnavailable },
        windows: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForWindow: { _ in throw CaptureEngineError.persistenceUnavailable },
        screenshotsForApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        framePage: { _, _, _ in throw CaptureEngineError.persistenceUnavailable },
        frameQuerySnapshot: { _ in throw CaptureEngineError.persistenceUnavailable },
        frameCount: { _ in throw CaptureEngineError.persistenceUnavailable },
        framesByID: { _ in throw CaptureEngineError.persistenceUnavailable },
        timelineForSession: { _ in throw CaptureEngineError.persistenceUnavailable },
        timelineForWindow: { _, _ in throw CaptureEngineError.persistenceUnavailable },
        timelineForApp: { _ in throw CaptureEngineError.persistenceUnavailable },
        sessionTimeline: { _ in throw CaptureEngineError.persistenceUnavailable }
    )
}

nonisolated extension UUID {
    var databaseID: String {
        uuidString
    }
}

nonisolated extension Date {
    var databaseTime: TimeInterval {
        timeIntervalSince1970
    }

    init(databaseTime: TimeInterval) {
        self.init(timeIntervalSince1970: databaseTime)
    }
}
