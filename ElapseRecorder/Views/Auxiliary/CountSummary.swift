import SFSafeSymbols
import SwiftUI

struct CountSummary: View {
    struct Item {
        var text: String
        var systemSymbol: SFSymbol
        var isMonospaced: Bool

        init(value: Int, systemSymbol: SFSymbol, isMonospaced: Bool = true) {
            text = value.formatted()
            self.systemSymbol = systemSymbol
            self.isMonospaced = isMonospaced
        }

        init(text: String, systemSymbol: SFSymbol, isMonospaced: Bool = false) {
            self.text = text
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
            Text(item.text)
                .monospaced()
        } else {
            Text(item.text)
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
