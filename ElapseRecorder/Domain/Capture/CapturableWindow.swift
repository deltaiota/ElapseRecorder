import CoreGraphics
import Foundation

nonisolated struct CapturableWindow: Equatable, Identifiable {
    var id: Int {
        systemWindowID
    }

    var systemWindowID: Int
    var title: String?
    var frame: CGRect
    var layer: Int
    var isOnScreen: Bool
    /// True when the window is stowed on the Stage Manager strip. No public, sandbox-safe
    /// ScreenCaptureKit/CoreGraphics property distinguishes this — when stowed, the window
    /// stays on-screen but its reported frame shrinks to a small strip thumbnail while its
    /// real size (read via Accessibility) is unchanged. The live layer sets this by
    /// cross-checking the presented frame size against the app's real Accessibility window
    /// sizes; a mismatch means the window is being presented as a stowed proxy.
    var isStageManagerStowed: Bool = false

    var shouldCapture: Bool {
        isOnScreen
            && !isStageManagerStowed
            && layer == 0
            && frame.width >= 80
            && frame.height >= 80
            && !frame.isEmpty
    }

    static func capturableWindows(from windows: [Self]) -> [Self] {
        windows.filter { window in
            window.shouldCapture
                && !window.isLikelyAttachedSheetOrOverlay(in: windows)
        }
    }

    private func isLikelyAttachedSheetOrOverlay(in windows: [Self]) -> Bool {
        guard hasSystemPanelTitle else { return false }

        return windows.contains { other in
            other.systemWindowID != systemWindowID
                && other.shouldCapture
                && other.frame.area > frame.area
                && frame.intersection(other.frame).area >= frame.area * 0.85
        }
    }

    private var hasSystemPanelTitle: Bool {
        guard let title else { return true }

        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "open", "save", "save as", "export", "import", "print":
            return true
        default:
            return false
        }
    }
}

private nonisolated extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite, !isEmpty else { return 0 }
        return width * height
    }
}
