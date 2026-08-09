import ComposableArchitecture
import Foundation

struct ViewerFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var apps: [AppCaptureSummary] = []
        var sessions: [CaptureSessionSummary] = []
        var windows: [WindowCaptureSummary] = []
        var sessionTimeline: SessionTimeline?
        var windowTimelineEntries: [CaptureTimelineEntry] = []
        var flatTimelineEntries: [CaptureTimelineEntry] = []
        /// The complete frame scope currently represented by the bounded presentation page.
        var frameQuery: FrameQuery?
        var nextFrameCursor: FrameCursor?
        var frameTotalCount = 0
        var isLoadingMoreFrames = false
        /// Cadence is computed by streaming the complete scope, never from the visible page.
        var averageScreenshotInterval: TimeInterval?
        var cadenceSelection: FrameSelection?
        var selectedBundleIdentifier: String?
        var selectedSessionID: UUID?
        var selectedWindowID: UUID?
        var selectedSegment: WindowTitleSegment?
        var selectedScreenshotIDs: Set<UUID> = []
        var quickLookURL: URL?
        /// True from the moment an export is requested until it finishes/cancels — used to
        /// guard re-entry and disable the Export button (covers the destination-picker phase).
        var isExporting = false
        /// Non-nil only while frames are actually being encoded; drives the progress sheet.
        /// It stays nil during the AppKit save-panel phase so the two sheets never collide.
        var exportStatus: TimelapseExportStatus?
        /// True while a storage maintenance task (integrity sweep or bulk delete) is running.
        var isRunningStorageMaintenance = false
        /// The outcome of the most recent integrity sweep, shown in the storage management UI.
        var storageIntegrityResult: StorageIntegrityResult?
        /// True while the retention pruner is running, to guard against overlapping runs.
        var isEnforcingRetention = false
        var isShowingFlatGallery = false
        var isLoading = false
        var errorMessage: String?

        enum SessionListSelection: Hashable {
            case flat
            case session(id: UUID)
        }

        enum WindowPickerSelection: Hashable {
            case all
            case window(id: UUID)
        }

        var sessionListSelection: SessionListSelection? {
            get {
                if isShowingFlatGallery {
                    return .flat
                }

                guard let selectedSessionID else { return nil }
                return .session(id: selectedSessionID)
            }
            set {
                switch newValue {
                case .flat:
                    selectedSessionID = nil
                    isShowingFlatGallery = true
                case let .session(id):
                    selectedSessionID = id
                    isShowingFlatGallery = false
                case nil:
                    selectedSessionID = nil
                    isShowingFlatGallery = false
                }
            }
        }

        var windowPickerSelection: WindowPickerSelection {
            get {
                guard let selectedWindowID else { return .all }
                return .window(id: selectedWindowID)
            }
            set {
                switch newValue {
                case .all:
                    selectedWindowID = nil
                case let .window(id):
                    selectedWindowID = id
                }
            }
        }

        /// A session is selected but no specific window/segment is — show the lifecycle
        /// timeline graph rather than a screenshot grid.
        var isShowingTimelineGraph: Bool {
            selectedSessionID != nil && selectedWindowID == nil && !isShowingFlatGallery
        }
    }

    @CasePathable
    enum Action: Equatable {
        case task
        case appsLoaded([AppCaptureSummary])
        case appSelected(String?)
        case sessionsLoaded([CaptureSessionSummary])
        case sessionSelected(UUID?)
        case windowsLoaded([WindowCaptureSummary])
        case sessionTimelineLoaded(SessionTimeline)
        case windowSelected(UUID?)
        case windowSegmentSelected(windowID: UUID, segment: WindowTitleSegment)
        case windowPickerSelectionChanged(State.WindowPickerSelection)
        case timelineEntriesLoaded([CaptureTimelineEntry])
        case sessionListSelectionChanged(State.SessionListSelection?)
        case flatGallerySelected
        case flatTimelineEntriesLoaded([CaptureTimelineEntry])
        case framePageLoaded(query: FrameQuery, page: FramePage, appending: Bool)
        case loadMoreFramesRequested
        case cadenceLoaded(selection: FrameSelection, average: TimeInterval?)
        case captureScreenshotRecorded(ScreenshotRecord, bundleIdentifier: String)
        case captureUnavailableRecorded(CaptureUnavailableRecord)
        case segmentCommitted(handle: RecordingSessionHandle, frameIDs: [UUID])
        case screenshotSelectionChanged(Set<UUID>)
        case quickLookURLChanged(URL?)
        case quickLookRequested(ScreenshotRecord)
        case refresh
        case revealScreenshotInFinder(ScreenshotRecord)
        case exportSelectionRequested(FrameSelection)
        /// Retained for direct callers with an already-bounded ad-hoc frame set.
        case exportTimelapseRequested(frames: [ExportFrame])
        case exportCancelButtonTapped
        case exportStarted(options: ExportOptions, totalFrames: Int)
        case exportProgressed(TimelapseExportProgress)
        case exportCompleted(URL)
        case exportFailed(String)
        case exportCancelled
        case deleteSessionButtonTapped(CaptureSessionSummary)
        case deleteSelectedSessionButtonTapped
        case sessionDeleted(UUID)
        case runIntegritySweepButtonTapped
        case integritySweepFinished(StorageIntegrityResult)
        case bulkDeleteRequested(before: Date, bundleIdentifier: String?)
        case bulkDeleteFinished(deletedSessionCount: Int)
        case enforceRetentionRequested
        case retentionEnforced(deletedSessionCount: Int)
        case loadingFailed(String)
    }

    @Dependency(\.fileRevealClient) var fileReveal
    @Dependency(\.fileStorageClient) var fileStorage
    @Dependency(\.persistenceClient) var persistence
    @Dependency(\.storageCoordinatorClient) var storageCoordinator
    @Dependency(\.maintenanceServiceClient) var maintenance
    @Dependency(\.capturePreferencesClient) var preferences
    @Dependency(\.timelapseExportClient) var timelapseExport
    @Dependency(\.exportPanelClient) var exportPanel
    @Dependency(\.videoFrameExtractorClient) var videoFrameExtractor
    @Dependency(\.thumbnailClient) var thumbnail
    @Dependency(\.perceptualHashClient) var perceptualHash
    @Dependency(\.date) var date

    nonisolated enum CancelID: Hashable { case export }
}
