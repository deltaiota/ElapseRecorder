import AppKit
import Quartz
import SwiftUI

/// Drives the native Quick Look panel (`QLPreviewPanel`) for the screenshot grid.
///
/// All panel mutations are deferred off the SwiftUI layout pass and are idempotent, so
/// re-renders never re-enter the panel (which previously produced reentrant-layout
/// warnings and an AttributeGraph cycle). `openURL` only changes on open/close; arrow-key
/// navigation reports the new item through `onNavigate` and never changes `openURL`, so it
/// can't feed back into another present. Source frames come from the thumbnail registry,
/// giving the Finder-style zoom.
struct QuickLookPresenter: NSViewRepresentable {
    var urls: [URL]
    var openURL: URL?
    var onNavigate: (Int) -> Void
    var onClose: () -> Void

    func makeNSView(context _: Context) -> QuickLookHostView {
        let view = QuickLookHostView()
        configure(view)
        return view
    }

    func updateNSView(_ view: QuickLookHostView, context _: Context) {
        configure(view)
        view.apply(openURL: openURL)
    }

    static func dismantleNSView(_ view: QuickLookHostView, coordinator _: ()) {
        view.apply(openURL: nil)
    }

    private func configure(_ view: QuickLookHostView) {
        view.items = urls
        view.onNavigate = onNavigate
        view.onClose = onClose
    }
}

final class QuickLookHostView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [URL] = []
    var onNavigate: (Int) -> Void = { _ in }
    var onClose: () -> Void = {}

    private var presentedURL: URL?
    private var isObservingIndex = false

    override var acceptsFirstResponder: Bool {
        true
    }

    /// Reconcile the panel with the requested `openURL`. Deferred to the next runloop turn
    /// so it never runs inside a SwiftUI layout pass, and a no-op when already in the
    /// requested state.
    func apply(openURL: URL?) {
        guard openURL != presentedURL else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard openURL != presentedURL else { return }

            if let openURL {
                let wasOpen = presentedURL != nil
                presentedURL = openURL
                if wasOpen {
                    moveToItem(openURL)
                } else {
                    openPanel(at: openURL)
                }
            } else {
                presentedURL = nil
                closePanel()
            }
        }
    }

    private func openPanel(at url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        window?.makeFirstResponder(self)
        panel.makeKeyAndOrderFront(nil)
        moveToItem(url)
    }

    private func moveToItem(_ url: URL) {
        guard let index = items.firstIndex(of: url),
              let panel = QLPreviewPanel.shared(),
              panel.dataSource === self
        else { return }
        panel.reloadData()
        if panel.currentPreviewItemIndex != index {
            panel.currentPreviewItemIndex = index
        }
    }

    private func closePanel() {
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
        if presentedURL != nil {
            presentedURL = nil
            let onClose = onClose
            DispatchQueue.main.async { onClose() }
        }
    }

    // MARK: Data source

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items.indices.contains(index) ? items[index] as NSURL : nil
    }

    // MARK: Delegate (zoom source frame)

    func previewPanel(_: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = (item as? NSURL) as URL?,
              let frame = ThumbnailFrameRegistry.shared.frame(for: url)
        else { return .zero }
        return frame
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
        let index = panel.currentPreviewItemIndex
        let onNavigate = onNavigate
        DispatchQueue.main.async { onNavigate(index) }
    }
}
