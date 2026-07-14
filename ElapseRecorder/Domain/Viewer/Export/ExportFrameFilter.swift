import Foundation

/// Selects which of an ordered set of frames to keep when the export-time near-duplicate filter
/// is enabled. A frame is dropped when its perceptual hash is within `threshold` Hamming distance
/// of the previous kept frame; frames with an unknown hash (0, e.g. captured before hashing) are
/// always kept so old libraries aren't silently thinned.
nonisolated enum ExportFrameFilter {
    static let similarityThreshold = 4

    static func keptIndices(hashes: [UInt64], threshold: Int = similarityThreshold) -> [Int] {
        var kept: [Int] = []
        var lastHash: UInt64?

        for (index, hash) in hashes.enumerated() {
            if let last = lastHash, hash != 0, last != 0,
               PerceptualHash.distance(hash, last) <= threshold
            {
                continue
            }
            kept.append(index)
            lastHash = hash
        }
        return kept
    }
}
