import Foundation

/// Selects which of an ordered set of frames to keep when the export-time near-duplicate filter
/// is enabled. A frame is dropped when its perceptual hash is within `threshold` Hamming distance
/// of the previous kept frame. A `nil` hash is always kept and breaks the comparison chain so an
/// unreadable legacy value never causes unrelated frames to be discarded.
nonisolated enum ExportFrameFilter {
    static let similarityThreshold = 4

    /// Filters stored hashes. Zero is the legacy "not computed" sentinel.
    static func keptIndices(hashes: [UInt64], threshold: Int = similarityThreshold) -> [Int] {
        keptIndices(hashes: hashes.map { $0 == 0 ? nil : $0 }, threshold: threshold)
    }

    /// Filters resolved hashes. Unlike the stored representation, `.some(0)` is a valid dHash.
    static func keptIndices(hashes: [UInt64?], threshold: Int = similarityThreshold) -> [Int] {
        var kept: [Int] = []
        var lastHash: UInt64?

        for (index, hash) in hashes.enumerated() {
            guard let hash else {
                kept.append(index)
                lastHash = nil
                continue
            }
            if let last = lastHash, PerceptualHash.distance(hash, last) <= threshold {
                continue
            }
            kept.append(index)
            lastHash = hash
        }
        return kept
    }
}
