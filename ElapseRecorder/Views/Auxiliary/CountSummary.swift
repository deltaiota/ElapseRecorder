import SFSafeSymbols
import SwiftUI

struct CountSummary: View {
    struct Item {
        var label: Text
        var systemSymbol: SFSymbol
        var isMonospaced: Bool

        init(value: Int, systemSymbol: SFSymbol, isMonospaced: Bool = true) {
            label = Text(value.formatted())
            self.systemSymbol = systemSymbol
            self.isMonospaced = isMonospaced
        }

        init(text: String, systemSymbol: SFSymbol, isMonospaced: Bool = false) {
            label = Text(text)
            self.systemSymbol = systemSymbol
            self.isMonospaced = isMonospaced
        }

        /// Accepts a SwiftUI Text directly so callers can pass a self-updating timer
        /// (e.g. Text(date, style: .timer)) that SwiftUI refreshes on its own.
        init(label: Text, systemSymbol: SFSymbol, isMonospaced: Bool = false) {
            self.label = label
            self.systemSymbol = systemSymbol
            self.isMonospaced = isMonospaced
        }
    }

    var items: [Item]

    var body: some View {
        // Auto-shrink: offer the full row first, then progressively fewer items (dropping the
        // lowest-priority trailing items, e.g. disk space) so a narrow column hides items
        // instead of squeezing/truncating the text. ViewThatFits picks the widest that fits.
        ViewThatFits(in: .horizontal) {
            ForEach(candidateItemCounts, id: \.self) { count in
                summaryRow(itemCount: count)
            }
        }
    }

    /// Item counts from all items down to a single item, so the first (widest) layout that fits
    /// the available width wins; if none fit, ViewThatFits falls back to the smallest.
    private var candidateItemCounts: [Int] {
        guard items.count > 1 else { return [items.count] }
        return Array(stride(from: items.count, through: 1, by: -1))
    }

    @ViewBuilder
    private func summaryRow(itemCount: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.prefix(itemCount).enumerated()), id: \.offset) { offset, item in
                if offset > 0 {
                    Image(systemSymbol: .circleFill)
                        .font(.system(size: 3))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 2) {
                    Image(systemSymbol: item.systemSymbol)
                    itemText(item)
                }
            }
        }
        // Report the row's natural width to ViewThatFits so it can decide whether it fits.
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func itemText(_ item: Item) -> some View {
        if item.isMonospaced {
            item.label.monospaced()
        } else {
            item.label
        }
    }
}

#Preview {
    CountSummary(
        items: [
            .init(value: 3, systemSymbol: .clock),
            .init(value: 42, systemSymbol: .photo),
            .init(text: "01:23:45", systemSymbol: .timer, isMonospaced: true),
        ]
    )
    .padding()
}
