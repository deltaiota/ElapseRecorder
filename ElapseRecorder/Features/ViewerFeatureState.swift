import Foundation

extension ViewerFeature.State {
    var selectedSession: CaptureSessionSummary? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    /// A friendly default file name for an exported timelapse, based on the current app and
    /// session selection.
    var exportSuggestedFileName: String {
        let appName = selectedBundleIdentifier
            .flatMap { id in apps.first { $0.bundleIdentifier == id } }?
            .displayName ?? "Capture"

        if let startedAt = selectedSession?.startedAt {
            let stamp = startedAt.formatted(
                .verbatim(
                    "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
                    timeZone: .current,
                    calendar: .current
                )
            )
            return "\(appName) Timelapse \(stamp)"
        }
        return "\(appName) Timelapse"
    }

    mutating func clearSelection() {
        selectedBundleIdentifier = nil
        selectedSessionID = nil
        selectedWindowID = nil
        selectedSegment = nil
        clearScreenshotSelection()
        isShowingFlatGallery = false
        sessions = []
        windows = []
        sessionTimeline = nil
        windowTimelineEntries = []
        flatTimelineEntries = []
        clearFramePage()
    }

    mutating func clearFramePage() {
        frameQuery = nil
        nextFrameCursor = nil
        frameTotalCount = 0
        isLoadingMoreFrames = false
        averageScreenshotInterval = nil
        cadenceSelection = nil
    }

    /// Applies one persisted capture without re-querying and copying the full library. This path
    /// runs once per frame, so it must stay proportional to the small summary/timeline surfaces
    /// being updated rather than to the total number of stored screenshots.
    mutating func recordCapturedScreenshot(
        _ record: ScreenshotRecord,
        bundleIdentifier: String
    ) {
        let visibleEntries = isShowingFlatGallery ? flatTimelineEntries : windowTimelineEntries
        let wasVisible = visibleEntries.contains { $0.id == record.id }
        let matchesCurrentQuery = frameQuery?.matches(record, bundleIdentifier: bundleIdentifier) == true
        if let index = apps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            let previousLastCapture = apps[index].lastCapturedAt
            apps[index].screenshotCount += 1
            apps[index].sizeBytes += record.fileSizeBytes
            apps[index].lastCapturedAt = max(previousLastCapture ?? record.capturedAt, record.capturedAt)

            if let session = sessions.first(where: { $0.id == record.sessionID }),
               session.endedAt == nil
            {
                let priorEnd = max(session.startedAt, previousLastCapture ?? session.startedAt)
                apps[index].totalActiveDuration += max(0, record.capturedAt.timeIntervalSince(priorEnd))
            }
        }

        if let index = sessions.firstIndex(where: { $0.id == record.sessionID }) {
            sessions[index].screenshotCount += 1
            sessions[index].sizeBytes += record.fileSizeBytes
        }
        if let index = windows.firstIndex(where: { $0.id == record.windowID }) {
            windows[index].screenshotCount += 1
        }

        if isShowingFlatGallery, selectedBundleIdentifier == bundleIdentifier {
            Self.appendIfNew(.screenshot(record), to: &flatTimelineEntries)
        }
        if selectedSessionID == record.sessionID,
           selectedWindowID == record.windowID,
           selectedSegment.map({ record.capturedAt >= $0.startedAt && record.capturedAt <= $0.endedAt }) ?? true
        {
            Self.appendIfNew(.screenshot(record), to: &windowTimelineEntries)
        }

        if var timeline = sessionTimeline,
           timeline.sessionID == record.sessionID,
           let laneIndex = timeline.lanes.firstIndex(where: { $0.windowID == record.windowID })
        {
            timeline.lanes[laneIndex].diedAt = max(timeline.lanes[laneIndex].diedAt, record.capturedAt)
            timeline.lanes[laneIndex].screenshotCount += 1
            if let segmentIndex = timeline.lanes[laneIndex].segments.lastIndex(where: {
                record.capturedAt >= $0.startedAt && record.capturedAt <= $0.endedAt
            }) {
                timeline.lanes[laneIndex].segments[segmentIndex].screenshotCount += 1
            }
            sessionTimeline = timeline
        }
        if matchesCurrentQuery, !wasVisible {
            frameTotalCount += 1
        }
    }

    mutating func recordCaptureUnavailable(_ record: CaptureUnavailableRecord) {
        guard selectedSessionID == record.sessionID else { return }

        let entry = CaptureTimelineEntry.unavailable(record)
        if selectedWindowID != nil {
            Self.upsert(entry, in: &windowTimelineEntries)
        }
        if var timeline = sessionTimeline, timeline.sessionID == record.sessionID {
            if let index = timeline.unavailableSpans.lastIndex(where: { $0.startedAt == record.startedAt }) {
                timeline.unavailableSpans[index].endedAt = record.endedAt
            } else {
                timeline.unavailableSpans.append(TimeSpan(startedAt: record.startedAt, endedAt: record.endedAt))
            }
            sessionTimeline = timeline
        }
    }

    private static func appendIfNew(
        _ entry: CaptureTimelineEntry,
        to entries: inout [CaptureTimelineEntry]
    ) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
    }

    static func appendUnique(
        _ newEntries: [CaptureTimelineEntry],
        to entries: inout [CaptureTimelineEntry]
    ) {
        var existingIDs = Set(entries.map(\.id))
        entries.append(contentsOf: newEntries.filter { existingIDs.insert($0.id).inserted })
    }

    private static func upsert(
        _ entry: CaptureTimelineEntry,
        in entries: inout [CaptureTimelineEntry]
    ) {
        if entries.last?.id == entry.id {
            entries[entries.count - 1] = entry
        } else if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    mutating func clearScreenshotSelection() {
        selectedScreenshotIDs = []
        quickLookURL = nil
    }

    func screenshotID(forFileURL url: URL) -> UUID? {
        let entries = isShowingFlatGallery ? flatTimelineEntries : windowTimelineEntries
        for entry in entries {
            if case let .screenshot(record) = entry, record.fileURL == url {
                return record.id
            }
        }
        return nil
    }
}
