nonisolated enum PerceptualHash {
    /// Hamming distance between two 64-bit hashes: the number of differing bits.
    static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}
