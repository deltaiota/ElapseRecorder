import AppKit
import Quartz
import SwiftUI

/// Drives the native Quick Look panel (`QLPreviewPanel`) for the screenshot grid.
///
/// Using the AppKit panel directly (instead of the SwiftUI `quickLookPreview`
/// modifier) gives the Finder-style present/dismiss animation and avoids the
/// modifier's console warnings. Navigating with the arrow keys inside the panel
/// writes the new item back through `currentURL`, so the grid selection can follow.
struct QuickLookPresenter: NSViewRepresentable {
    var urls: [URL]
    @Binding var currentURL: URL?

    func makeNSView(context _: Context) -> QuickLookHostView {
        let view = QuickLookHostView()
        configure(view)
        return view
    }

    func updateNSView(_ view: QuickLookHostView, context _: Context) {
        configure(view)
        view.items = urls

        if let currentURL, let index = urls.firstIndex(of: currentURL) {
            view.present(at: index)
        } else {
            view.dismiss()
        }
    }

    private func configure(_ view: QuickLookHostView) {
        view.items = urls
        view.onIndexChange = { index in
            guard urls.indices.contains(index) else { return }
            let url = urls[index]
            if currentURL != url { currentURL = url }
        }
        view.onClose = {
            if currentURL != nil { currentURL = nil }
        }
    }
}

final class QuickLookHostView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [URL] = []
    var onIndexChange: (Int) -> Void = { _ in }
    var onClose: () -> Void = {}

    private var isObservingIndex = false

    override var acceptsFirstResponder: Bool {
        true
    }

    func present(at index: Int) {
        guard let panel = QLPreviewPanel.shared() else { return }
        window?.makeFirstResponder(self)

        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }

        if panel.currentPreviewItemIndex != index, items.indices.contains(index) {
            panel.currentPreviewItemIndex = index
        }
    }

    func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible,
              panel.dataSource === self
        else { return }
        panel.orderOut(nil)
    }

    // MARK: Responder-chain control

    override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        if !isObservingIndex {
            panel.addObserver(self, forKeyPath: "currentPreviewItemIndex", options: [.new], context: nil)
            isObservingIndex = true
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if isObservingIndex {
            panel.removeObserver(self, forKeyPath: "currentPreviewItemIndex")
            isObservingIndex = false
        }
        onClose()
    }

    // MARK: Data source

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items.indices.contains(index) ? items[index] as NSURL : nil
    }

    // MARK: Navigation feedback

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "currentPreviewItemIndex", let panel = object as? QLPreviewPanel else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        onIndexChange(panel.currentPreviewItemIndex)
    }
}
