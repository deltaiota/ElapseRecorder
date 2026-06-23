import AppKit
import SwiftUI

/// Tracks the on-screen frame of each visible thumbnail so Quick Look can zoom from
/// (and back to) the originating cell, the way Finder does.
final class ThumbnailFrameRegistry: @unchecked Sendable {
    static let shared = ThumbnailFrameRegistry()

    private let lock = NSLock()
    private var frames: [URL: CGRect] = [:]

    func set(_ frame: CGRect, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        frames[url] = frame
    }

    func remove(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        frames[url] = nil
    }

    func frame(for url: URL) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return frames[url]
    }
}

/// Reports a cell's screen frame into the registry. Placed in a thumbnail's background;
/// uses AppKit conversion (more reliable than SwiftUI coordinate-space math for screen
/// coordinates).
struct ThumbnailFrameReporter: NSViewRepresentable {
    let url: URL

    func makeNSView(context _: Context) -> FrameReportingView {
        let view = FrameReportingView()
        view.url = url
        return view
    }

    func updateNSView(_ view: FrameReportingView, context _: Context) {
        view.url = url
        view.report()
    }

    static func dismantleNSView(_ view: FrameReportingView, coordinator _: ()) {
        view.clear()
    }
}

final class FrameReportingView: NSView {
    var url: URL?

    override func layout() {
        super.layout()
        report()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { clear() }
    }

    func report() {
        guard let url, let window else {
            clear()
            return
        }
        let rectInWindow = convert(bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        ThumbnailFrameRegistry.shared.set(screenRect, for: url)
    }

    func clear() {
        if let url {
            ThumbnailFrameRegistry.shared.remove(url)
        }
    }
}
