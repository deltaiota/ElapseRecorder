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
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
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
