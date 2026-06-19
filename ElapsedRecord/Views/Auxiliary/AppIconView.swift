import AppKit
import SFSafeSymbols
import SwiftUI

struct AppIconView: View {
    let icon: NSImage?

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(1/1, contentMode: .fit)
                .scaledToFit()
        } else {
            Image(systemSymbol: .app)
                .aspectRatio(1/1, contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }
}
