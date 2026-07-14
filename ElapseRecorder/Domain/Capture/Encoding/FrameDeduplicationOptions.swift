import Foundation

/// Settings controlling whether near-identical consecutive frames are skipped at capture time
/// to save storage. Two frames are "identical" when the Hamming distance between their dHashes
/// is at or below `hammingThreshold`. `heartbeat` bounds how long a window can be skipped: once
/// this much time has passed since the last kept frame, the next frame is kept regardless, so
/// long idle stretches still get a periodic marker.
nonisolated struct FrameDeduplicationOptions: Equatable {
    var isEnabled: Bool
    var hammingThreshold: Int
    var heartbeat: Duration

    static let defaultValue = Self(
        isEnabled: true,
        hammingThreshold: 4,
        heartbeat: .seconds(300)
    )

    /// Whether `candidate` should be treated as identical to a previously kept frame captured
    /// `elapsed` ago, and therefore skipped.
    func shouldSkip(distance: Int, elapsed: Duration) -> Bool {
        guard isEnabled else { return false }
        guard elapsed < heartbeat else { return false }
        return distance <= hammingThreshold
    }
}

nonisolated enum PerceptualHash {
    /// Hamming distance between two 64-bit hashes: the number of differing bits.
    static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}
