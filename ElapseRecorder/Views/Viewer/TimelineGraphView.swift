import SFSafeSymbols
import SwiftUI
import TranslateKit

/// Incremental v1 of the session lifecycle timeline: each window is a vertical lane
/// (a column), and its title history is shown as a top-to-bottom stack of constant-title
/// segments. Tapping a lane header opens the whole window; tapping a segment opens that
/// title's screenshots. Time is chronological but not yet drawn to scale — proportional
/// spacing and git-style connectors are a later visual pass.
struct TimelineGraphView: View {
    let timeline: SessionTimeline
    var selectedWindowID: UUID?
    var selectedSegmentID: UUID?
    var onSelectWindow: (UUID) -> Void
    var onSelectSegment: (UUID, WindowTitleSegment) -> Void

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 28) {
                ForEach(timeline.lanes) { lane in
                    laneColumn(lane)
                }
            }
            .padding(24)
        }
        .background(.background)
        .overlay {
            if timeline.lanes.isEmpty {
                ContentUnavailableView(
                    "No Windows Captured",
                    systemSymbol: .macwindowBadgePlus,
                    description: Text("This session has no recorded windows yet.")
                )
            }
        }
    }

    private func laneColumn(_ lane: WindowLane) -> some View {
        VStack(spacing: 0) {
            laneHeader(lane)

            ForEach(Array(lane.segments.enumerated()), id: \.element.id) { index, segment in
                connector(isFirst: index == 0)
                segmentNode(lane: lane, segment: segment)
            }
        }
        .frame(width: 200)
    }

    private func laneHeader(_ lane: WindowLane) -> some View {
        let isSelected = selectedWindowID == lane.windowID && selectedSegmentID == nil

        return Button {
            onSelectWindow(lane.windowID)
        } label: {
            VStack(spacing: 4) {
                Image(systemSymbol: .macwindow)
                    .font(.title3)
                Text(#tk("Window \(lane.displayNumber)"))
                    .font(.headline)
                Text(#tk("\(lane.screenshotCount) screenshots"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func connector(isFirst _: Bool) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 2, height: 16)
    }

    private func segmentNode(lane: WindowLane, segment: WindowTitleSegment) -> some View {
        let isSelected = selectedSegmentID == segment.id

        return Button {
            onSelectSegment(lane.windowID, segment)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 9, height: 9)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: segment))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Label(durationText(for: segment), systemSymbol: .clock)
                            .monospacedDigit()
                        Label("\(segment.screenshotCount)", systemSymbol: .photo)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(Text(segment.startedAt, format: .dateTime.hour().minute().second()))
    }

    private func title(for segment: WindowTitleSegment) -> String {
        if let title = segment.title, !title.isEmpty {
            return title
        }
        return String(localized: "Untitled")
    }

    private func durationText(for segment: WindowTitleSegment) -> String {
        let seconds = max(0, segment.endedAt.timeIntervalSince(segment.startedAt))
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        )
    }
}
