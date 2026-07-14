import Foundation

/// Pure helpers for constraining capture output resolution.
///
/// Windows on Retina / high-DPI displays are captured at their physical backing resolution
/// (e.g. a 6K editor window is 6016×3384 ≈ 20 MP), which dominates on-disk footprint. Capping
/// the longest edge keeps frames crisp enough for a fast-forward review timelapse while cutting
/// storage roughly by the square of the scale factor.
nonisolated enum CaptureResolution {
    /// Clamps a physical pixel size so its longest edge does not exceed `maxDimension`, preserving
    /// aspect ratio. `maxDimension <= 0` means "no cap". Never upscales.
    static func cappedPixelSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        let width = max(1, width)
        let height = max(1, height)
        let longestEdge = max(width, height)

        guard maxDimension > 0, longestEdge > maxDimension else {
            return (width, height)
        }

        let scale = Double(maxDimension) / Double(longestEdge)
        let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }
}
