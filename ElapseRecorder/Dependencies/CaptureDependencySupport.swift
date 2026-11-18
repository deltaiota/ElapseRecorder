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
        retentionSnapshot: {
            reportIssue("PersistenceClient.retentionSnapshot is unimplemented")
            return RetentionSnapshot(endedSessionsOldestFirst: [], activeSizeBytes: 0, activeFrameCount: 0)
        },
        prepareSessionDeletion: { _ in
            reportIssue("PersistenceClient.prepareSessionDeletion is unimplemented")
            return nil
        },
        pendingSessionDeletions: {
            reportIssue("PersistenceClient.pendingSessionDeletions is unimplemented")
            return []
        },
        finalizeSessionDeletion: { _ in reportIssue("PersistenceClient.finalizeSessionDeletion is unimplemented") },
        upsertWindow: { _ in reportIssue("PersistenceClient.upsertWindow is unimplemented") },
        recordScreenshot: { _ in reportIssue("PersistenceClient.recordScreenshot is unimplemented") },
        recordCaptureUnavailable: { _ in reportIssue("PersistenceClient.recordCaptureUnavailable is unimplemented") },
        registerSpoolFrame: { _ in reportIssue("PersistenceClient.registerSpoolFrame is unimplemented") },
        markSpoolFrameReady: { _, _ in
            reportIssue("PersistenceClient.markSpoolFrameReady is unimplemented")
            throw CaptureEngineError.persistenceUnavailable
        },
        failSpoolFrame: { _, _ in reportIssue("PersistenceClient.failSpoolFrame is unimplemented") },
        recoverSpoolFrames: { _ in
            reportIssue("PersistenceClient.recoverSpoolFrames is unimplemented")
            return []
        },
        pendingSpoolFrames: { _ in
            reportIssue("PersistenceClient.pendingSpoolFrames is unimplemented")
            return []
        },
        spoolByteCount: {
            reportIssue("PersistenceClient.spoolByteCount is unimplemented")
            return 0
        },
        createSegmentJob: { _ in reportIssue("PersistenceClient.createSegmentJob is unimplemented") },
        leaseSegmentJob: { _, _, _ in
            reportIssue("PersistenceClient.leaseSegmentJob is unimplemented")
            return nil
        },
        markSegmentJobPublished: { _ in
            reportIssue("PersistenceClient.markSegmentJobPublished is unimplemented")
        },
        commitSegmentJob: { _ in
            reportIssue("PersistenceClient.commitSegmentJob is unimplemented")
            return []
        },
        failSegmentJob: { _, _, _, _, _ in reportIssue("PersistenceClient.failSegmentJob is unimplemented") },
        requeueSegmentJob: { _, _ in
            reportIssue("PersistenceClient.requeueSegmentJob is unimplemented")
        },
        recoverSegmentJobs: { _ in
            reportIssue("PersistenceClient.recoverSegmentJobs is unimplemented")
            return []
        },
        pendingSegmentCleanups: {
            reportIssue("PersistenceClient.pendingSegmentCleanups is unimplemented")
            return []
        },
        completeSegmentCleanup: { _ in
            reportIssue("PersistenceClient.completeSegmentCleanup is unimplemented")
        },
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
        framePage: { _, _, _ in
            reportIssue("PersistenceClient.framePage is unimplemented")
            return .empty
        },
        frameQuerySnapshot: { _ in
            reportIssue("PersistenceClient.frameQuerySnapshot is unimplemented")
            return FrameQuerySnapshot(selection: .ids([]), count: 0)
        },
        frameCount: { _ in
            reportIssue("PersistenceClient.frameCount is unimplemented")
            return 0
        },

        framesByID: { _ in
            reportIssue("PersistenceClient.framesByID is unimplemented")
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
