import AppKit
import SFSafeSymbols
import SwiftUI
import TranslateKit

private let timelinePalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red]

private func laneColor(_ index: Int) -> Color {
    timelinePalette[index % timelinePalette.count]
}

/// Vertical, git-style lifecycle timeline for one session. Time runs top to bottom, drawn
/// to scale. Each window is a coloured lane that begins at its window tag (the coloured dot
/// inside the tag is the lane's start) and ends at a hollow "died" cap, with hollow nodes
/// at each rename. Stretches where the window wasn't capturable are drawn dotted. Window
/// tags stick to the top while their lane is in view. Title segments are tappable.
struct TimelineGraphView: View {
    let timeline: SessionTimeline
    var selectedWindowID: UUID?
    var selectedSegmentID: UUID?
    var onSelectWindow: (UUID) -> Void
    var onSelectSegment: (UUID, WindowTitleSegment) -> Void

    @State private var scrollY: CGFloat = 0

    private let tagHeight: CGFloat = 24
    private let dotCenterInTag: CGFloat = 13

    var body: some View {
        if timeline.lanes.isEmpty {
            ContentUnavailableView(
                "No Windows Captured",
                systemSymbol: .macwindowBadgePlus,
                description: Text("This session has no recorded windows yet.")
            )
        } else {
            let metrics = metrics
            ScrollView([.vertical, .horizontal]) {
                ZStack(alignment: .topLeading) {
                    TimelineCanvas(timeline: timeline, selectedSegmentID: selectedSegmentID, metrics: metrics)
                        .equatable()
                        .allowsHitTesting(false)

                    gutterLabels(metrics)
                    segmentBlocks(metrics)
                    stickyTags(metrics)
                }
                .frame(width: metrics.totalWidth, height: metrics.contentHeight, alignment: .topLeading)
                .padding(.trailing, 28)
                .padding(.bottom, 28)
            }
            .background(.background)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, newValue in
                scrollY = newValue
            }
        }
    }

    // MARK: Gutter (time labels with detailed hover help)

    private func gutterLabels(_ metrics: TimelineMetrics) -> some View {
        ForEach(metrics.tickDates(), id: \.self) { date in
            Text(date, format: .dateTime.hour().minute())
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: metrics.gutterWidth - 12, alignment: .trailing)
                .contentShape(.rect)
                .help(Text(date, format: .dateTime.year().month().day().hour().minute().second()))
                .offset(x: 0, y: metrics.y(date) - 6)
        }
    }

    // MARK: Tappable segments + title chips

    private func segmentBlocks(_ metrics: TimelineMetrics) -> some View {
        ForEach(Array(timeline.lanes.enumerated()), id: \.element.id) { index, lane in
            ForEach(lane.segments) { segment in
                segmentBlock(lane: lane, segment: segment, color: laneColor(index), metrics: metrics)
            }
        }
    }

    private func segmentBlock(lane: WindowLane, segment: WindowTitleSegment, color: Color, metrics: TimelineMetrics) -> some View {
        let y0 = metrics.y(segment.startedAt)
        let height = max(20, metrics.y(segment.endedAt) - y0)
        let isSelected = selectedSegmentID == segment.id
        // The first segment starts where the window tag rests, so push its title below the
        // tag to avoid the tag covering it; later segments only clear their small node.
        let isFirst = lane.segments.first?.id == segment.id
        let titleY: CGFloat = isFirst ? tagHeight / 2 + 8 : 4

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())

            Text(title(for: segment))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    isSelected ? AnyShapeStyle(color.opacity(0.22)) : AnyShapeStyle(.thinMaterial),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(.clear), lineWidth: 1))
                .frame(maxWidth: metrics.laneWidth - metrics.lineInset - 16, alignment: .leading)
                .offset(x: metrics.lineInset + 10, y: titleY)
                .allowsHitTesting(false)
        }
        .frame(width: metrics.laneWidth, height: height, alignment: .topLeading)
        .offset(x: metrics.laneOriginX(index(of: lane)), y: y0)
        .onTapGesture { onSelectSegment(lane.windowID, segment) }
        .help(Text(#tk("\(title(for: segment)) · \(segment.screenshotCount) screenshots")))
    }

    // MARK: Sticky window tags (the lane's start point)

    private func stickyTags(_ metrics: TimelineMetrics) -> some View {
        ForEach(Array(timeline.lanes.enumerated()), id: \.element.id) { index, lane in
            windowTag(lane, color: laneColor(index))
                .offset(
                    x: metrics.laneLineX(index) - dotCenterInTag,
                    y: stickyTop(lane: lane, metrics: metrics)
                )
        }
    }

    private func windowTag(_ lane: WindowLane, color: Color) -> some View {
        let isSelected = selectedWindowID == lane.windowID && selectedSegmentID == nil

        return Button {
            onSelectWindow(lane.windowID)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(#tk("Window \(lane.displayNumber)"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Image(systemSymbol: .photo)
                    Text("\(lane.screenshotCount)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: tagHeight)
            .background(
                isSelected ? AnyShapeStyle(color.opacity(0.2)) : AnyShapeStyle(.regularMaterial),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(.separator), lineWidth: 1))
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    /// Pin the tag to the top of the viewport, but never above the lane's start nor below
    /// its end — so it stays visible only while the window's lane is on screen.
    private func stickyTop(lane: WindowLane, metrics: TimelineMetrics) -> CGFloat {
        let restTop = metrics.y(lane.bornAt) - tagHeight / 2
        let endTop = metrics.y(lane.diedAt) - tagHeight / 2
        return min(max(scrollY + 6, restTop), max(restTop, endTop))
    }

    // MARK: Geometry helpers

    private func index(of lane: WindowLane) -> Int {
        timeline.lanes.firstIndex(where: { $0.id == lane.id }) ?? 0
    }

    private var metrics: TimelineMetrics {
        let start = timeline.startedAt
        let duration = max(1, effectiveEnd.timeIntervalSince(start))
        let raw = CGFloat(duration) + 88
        let contentHeight = min(max(raw, 480), 5000)
        return TimelineMetrics(
            start: start,
            duration: duration,
            contentHeight: contentHeight,
            topPadding: 52,
            drawable: contentHeight - 88,
            gutterWidth: 76,
            laneWidth: 172,
            lineInset: 22,
            laneCount: timeline.lanes.count
        )
    }

    private var effectiveEnd: Date {
        var candidates: [Date] = [timeline.startedAt]
        candidates.append(contentsOf: timeline.lanes.map(\.diedAt))
        candidates.append(contentsOf: timeline.unavailableSpans.map(\.endedAt))
        if let endedAt = timeline.endedAt {
            candidates.append(endedAt)
        }
        return candidates.max() ?? timeline.startedAt
    }

    private func title(for segment: WindowTitleSegment) -> String {
        if let title = segment.title, !title.isEmpty {
            return title
        }
        return String(localized: "Untitled")
    }
}

// MARK: - Geometry

struct TimelineMetrics: Equatable {
    var start: Date
    var duration: TimeInterval
    var contentHeight: CGFloat
    var topPadding: CGFloat
    var drawable: CGFloat
    var gutterWidth: CGFloat
    var laneWidth: CGFloat
    var lineInset: CGFloat
    var laneCount: Int

    var totalWidth: CGFloat {
        gutterWidth + laneWidth * CGFloat(laneCount)
    }

    func y(_ date: Date) -> CGFloat {
        topPadding + CGFloat(date.timeIntervalSince(start) / duration) * drawable
    }

    func laneOriginX(_ index: Int) -> CGFloat {
        gutterWidth + laneWidth * CGFloat(index)
    }

    func laneLineX(_ index: Int) -> CGFloat {
        laneOriginX(index) + lineInset
    }

    func tickDates() -> [Date] {
        let count = max(2, Int(drawable / 120))
        return (0 ... count).map { index in
            start.addingTimeInterval(duration * Double(index) / Double(count))
        }
    }
}

// MARK: - Static drawing (lines, dotted unavailable spans, nodes, gridlines)

/// The non-interactive layer of the timeline. Isolated and `Equatable` so it is not
/// re-drawn while the user scrolls (only the sticky tags move on scroll).
private struct TimelineLineInterval {
    var start: Date
    var end: Date
    var isUnavailable: Bool
}

private struct TimelineCanvas: View, Equatable {
    var timeline: SessionTimeline
    var selectedSegmentID: UUID?
    var metrics: TimelineMetrics

    private let nodeFill = Color(nsColor: .windowBackgroundColor)

    var body: some View {
        Canvas { context, _ in
            drawGridlines(context)

            for (index, lane) in timeline.lanes.enumerated() {
                draw(lane: lane, color: laneColor(index), context: context)
            }
        }
        .frame(width: metrics.totalWidth, height: metrics.contentHeight)
    }

    private func drawGridlines(_ context: GraphicsContext) {
        for date in metrics.tickDates() {
            var path = Path()
            let y = metrics.y(date)
            path.move(to: CGPoint(x: metrics.gutterWidth - 8, y: y))
            path.addLine(to: CGPoint(x: metrics.totalWidth, y: y))
            context.stroke(path, with: .color(.gray.opacity(0.15)), lineWidth: 1)
        }
    }

    private func draw(lane: WindowLane, color: Color, context: GraphicsContext) {
        let x = metrics.laneLineX(laneIndex(lane))

        for interval in lineIntervals(lane) {
            var path = Path()
            path.move(to: CGPoint(x: x, y: metrics.y(interval.start)))
            path.addLine(to: CGPoint(x: x, y: metrics.y(interval.end)))
            if interval.isUnavailable {
                context.stroke(
                    path,
                    with: .color(color.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 5])
                )
            } else {
                context.stroke(
                    path,
                    with: .color(color.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
            }
        }

        if let selectedSegmentID, let segment = lane.segments.first(where: { $0.id == selectedSegmentID }) {
            var path = Path()
            path.move(to: CGPoint(x: x, y: metrics.y(segment.startedAt)))
            path.addLine(to: CGPoint(x: x, y: metrics.y(segment.endedAt)))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }

        node(at: CGPoint(x: x, y: metrics.y(lane.diedAt)), radius: 5.5, color: color, context: context)
        for segment in lane.segments.dropFirst() {
            node(at: CGPoint(x: x, y: metrics.y(segment.startedAt)), radius: 4.5, color: color, context: context)
        }
    }

    private func node(at center: CGPoint, radius: CGFloat, color: Color, context: GraphicsContext) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(nodeFill))
        context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2.5)
    }

    private func laneIndex(_ lane: WindowLane) -> Int {
        timeline.lanes.firstIndex(where: { $0.id == lane.id }) ?? 0
    }

    /// Break the lane into solid (captured) and dotted (unavailable) intervals.
    private func lineIntervals(_ lane: WindowLane) -> [TimelineLineInterval] {
        let born = lane.bornAt
        let died = max(lane.bornAt, lane.diedAt)
        guard born < died else { return [] }

        var bounds: Set<Date> = [born, died]
        for span in timeline.unavailableSpans {
            let clippedStart = max(born, span.startedAt)
            let clippedEnd = min(died, span.endedAt)
            if clippedStart < clippedEnd {
                bounds.insert(clippedStart)
                bounds.insert(clippedEnd)
            }
        }

        let sorted = bounds.sorted()
        return (0 ..< sorted.count - 1).map { index in
            let start = sorted[index]
            let end = sorted[index + 1]
            let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            return TimelineLineInterval(
                start: start,
                end: end,
                isUnavailable: timeline.unavailableSpans.contains {
                    $0.startedAt <= midpoint && midpoint < $0.endedAt
                }
            )
        }
    }
}

#Preview {
    TimelineGraphView(
        timeline: SessionTimeline(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 600),
            lanes: [
                WindowLane(
                    windowID: UUID(),
                    displayNumber: 1,
                    systemWindowID: 1,
                    bornAt: Date(timeIntervalSince1970: 0),
                    diedAt: Date(timeIntervalSince1970: 600),
                    segments: [
                        WindowTitleSegment(id: UUID(), title: "Untitled", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 220), screenshotCount: 5),
                        WindowTitleSegment(id: UUID(), title: "Report.txt", startedAt: Date(timeIntervalSince1970: 220), endedAt: Date(timeIntervalSince1970: 600), screenshotCount: 12),
                    ],
                    screenshotCount: 17
                ),
                WindowLane(
                    windowID: UUID(),
                    displayNumber: 2,
                    systemWindowID: 2,
                    bornAt: Date(timeIntervalSince1970: 120),
                    diedAt: Date(timeIntervalSince1970: 480),
                    segments: [
                        WindowTitleSegment(id: UUID(), title: "Reference Image", startedAt: Date(timeIntervalSince1970: 120), endedAt: Date(timeIntervalSince1970: 480), screenshotCount: 8),
                    ],
                    screenshotCount: 8
                ),
            ],
            unavailableSpans: [
                TimeSpan(startedAt: Date(timeIntervalSince1970: 300), endedAt: Date(timeIntervalSince1970: 360)),
            ]
        ),
        selectedWindowID: nil,
        selectedSegmentID: nil,
        onSelectWindow: { _ in },
        onSelectSegment: { _, _ in }
    )
    .frame(width: 640, height: 720)
}
