import SFSafeSymbols
import SwiftUI
import TranslateKit

/// Vertical, git-style lifecycle timeline for one session. Time runs top to bottom, drawn
/// to scale: each window is a coloured lane positioned by its real first/last-seen times,
/// with a filled "born" cap, a hollow "died" cap, and hollow nodes at each rename. Title
/// segments are tappable (open that title's screenshots); the window header opens the whole
/// window. Stretches where no window was capturable are drawn as full-width bands.
struct TimelineGraphView: View {
    let timeline: SessionTimeline
    var selectedWindowID: UUID?
    var selectedSegmentID: UUID?
    var onSelectWindow: (UUID) -> Void
    var onSelectSegment: (UUID, WindowTitleSegment) -> Void

    private let topPadding: CGFloat = 52
    private let bottomPadding: CGFloat = 36
    private let gutterWidth: CGFloat = 76
    private let laneWidth: CGFloat = 172
    private let lineInset: CGFloat = 22
    private let minContentHeight: CGFloat = 480
    private let maxContentHeight: CGFloat = 5000
    private let pointsPerSecond: CGFloat = 1

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red]

    var body: some View {
        if timeline.lanes.isEmpty {
            ContentUnavailableView(
                "No Windows Captured",
                systemSymbol: .macwindowBadgePlus,
                description: Text("This session has no recorded windows yet.")
            )
        } else {
            content
        }
    }

    private var content: some View {
        let metrics = metrics
        return ScrollView([.vertical, .horizontal]) {
            ZStack(alignment: .topLeading) {
                background(metrics)

                HStack(alignment: .top, spacing: 0) {
                    timeGutter(metrics)

                    ForEach(Array(timeline.lanes.enumerated()), id: \.element.id) { index, lane in
                        laneColumn(lane, color: Self.color(index), metrics: metrics)
                    }
                }
            }
            .frame(width: metrics.totalWidth, height: metrics.contentHeight, alignment: .topLeading)
            .padding(.trailing, 28)
            .padding(.bottom, 28)
        }
        .background(.background)
    }

    // MARK: Background (gridlines + unavailable bands)

    private func background(_ metrics: Metrics) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(tickDates(metrics), id: \.self) { date in
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: metrics.totalWidth - metrics.gutterWidth + 8, height: 1)
                    .offset(x: metrics.gutterWidth - 8, y: metrics.y(date))
            }

            ForEach(Array(timeline.unavailableSpans.enumerated()), id: \.offset) { _, span in
                unavailableBand(span, metrics: metrics)
            }
        }
        .frame(width: metrics.totalWidth, height: metrics.contentHeight, alignment: .topLeading)
    }

    private func unavailableBand(_ span: TimeSpan, metrics: Metrics) -> some View {
        let y0 = metrics.y(span.startedAt)
        let height = max(2, metrics.y(span.endedAt) - y0)

        return Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .frame(width: metrics.totalWidth - metrics.gutterWidth, height: height, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                Label("Unavailable", systemSymbol: .eyeSlash)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .opacity(height > 22 ? 1 : 0)
            }
            .clipped()
            .offset(x: metrics.gutterWidth, y: y0)
    }

    private func timeGutter(_ metrics: Metrics) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(tickDates(metrics), id: \.self) { date in
                Text(date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.gutterWidth - 12, alignment: .trailing)
                    .offset(x: 0, y: metrics.y(date) - 6)
            }
        }
        .frame(width: metrics.gutterWidth, height: metrics.contentHeight, alignment: .topLeading)
    }

    // MARK: Lane

    private func laneColumn(_ lane: WindowLane, color: Color, metrics: Metrics) -> some View {
        let yBorn = metrics.y(lane.bornAt)
        let yDied = metrics.y(lane.diedAt)

        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(color.opacity(0.85))
                .frame(width: 3, height: max(3, yDied - yBorn))
                .offset(x: lineInset - 1.5, y: yBorn)

            ForEach(lane.segments) { segment in
                segmentLayer(lane: lane, segment: segment, color: color, metrics: metrics)
            }

            node(color: color, filled: true)
                .offset(x: lineInset - 6, y: yBorn - 6)
            node(color: color, filled: false)
                .offset(x: lineInset - 6, y: yDied - 6)

            ForEach(Array(lane.segments.dropFirst())) { segment in
                node(color: color, filled: false)
                    .offset(x: lineInset - 6, y: metrics.y(segment.startedAt) - 6)
            }

            windowHeader(lane, color: color)
                .offset(x: lineInset - 6, y: max(2, yBorn - 30))
        }
        .frame(width: laneWidth, height: metrics.contentHeight, alignment: .topLeading)
    }

    private func segmentLayer(lane: WindowLane, segment: WindowTitleSegment, color: Color, metrics: Metrics) -> some View {
        let y0 = metrics.y(segment.startedAt)
        let height = max(24, metrics.y(segment.endedAt) - y0)
        let isSelected = selectedSegmentID == segment.id

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: laneWidth, height: height)

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
                .overlay(Capsule().strokeBorder(isSelected ? color : .clear, lineWidth: 1))
                .frame(maxWidth: laneWidth - lineInset - 16, alignment: .leading)
                .offset(x: lineInset + 10, y: 4)
        }
        .frame(width: laneWidth, height: height, alignment: .topLeading)
        .offset(x: 0, y: y0)
        .onTapGesture { onSelectSegment(lane.windowID, segment) }
        .help(Text(#tk("\(title(for: segment)) · \(segment.screenshotCount) screenshots")))
    }

    private func windowHeader(_ lane: WindowLane, color: Color) -> some View {
        let isSelected = selectedWindowID == lane.windowID && selectedSegmentID == nil

        return Button {
            onSelectWindow(lane.windowID)
        } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(#tk("Window \(lane.displayNumber)"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.secondary)
                Label("\(lane.screenshotCount)", systemSymbol: .photo)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? AnyShapeStyle(color.opacity(0.2)) : AnyShapeStyle(.regularMaterial),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(.separator), lineWidth: 1))
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private func node(color: Color, filled: Bool) -> some View {
        Circle()
            .fill(filled ? AnyShapeStyle(color) : AnyShapeStyle(.background))
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(color, lineWidth: filled ? 0 : 2.5))
    }

    // MARK: Geometry

    private struct Metrics {
        var start: Date
        var duration: TimeInterval
        var contentHeight: CGFloat
        var topPadding: CGFloat
        var drawable: CGFloat
        var gutterWidth: CGFloat
        var laneWidth: CGFloat
        var laneCount: Int

        var totalWidth: CGFloat {
            gutterWidth + laneWidth * CGFloat(laneCount)
        }

        func y(_ date: Date) -> CGFloat {
            topPadding + CGFloat(date.timeIntervalSince(start) / duration) * drawable
        }
    }

    private var metrics: Metrics {
        let start = timeline.startedAt
        let duration = max(1, effectiveEnd.timeIntervalSince(start))
        let raw = CGFloat(duration) * pointsPerSecond + topPadding + bottomPadding
        let contentHeight = min(max(raw, minContentHeight), maxContentHeight)
        return Metrics(
            start: start,
            duration: duration,
            contentHeight: contentHeight,
            topPadding: topPadding,
            drawable: contentHeight - topPadding - bottomPadding,
            gutterWidth: gutterWidth,
            laneWidth: laneWidth,
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

    private func tickDates(_ metrics: Metrics) -> [Date] {
        let count = max(2, Int(metrics.drawable / 120))
        return (0 ... count).map { index in
            metrics.start.addingTimeInterval(metrics.duration * Double(index) / Double(count))
        }
    }

    private func title(for segment: WindowTitleSegment) -> String {
        if let title = segment.title, !title.isEmpty {
            return title
        }
        return String(localized: "Untitled")
    }

    private static func color(_ index: Int) -> Color {
        palette[index % palette.count]
    }
}
