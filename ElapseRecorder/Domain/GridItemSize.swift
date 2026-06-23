import Foundation

/// A grid-thumbnail edge length that can never leave its allowed range.
///
/// The bounds and step live on the type, and every way of producing a value — the
/// initializer, the `+`/`-` operators, and `RawRepresentable` decoding — funnels through
/// the same clamp, so callers can add or subtract freely without bounds-checking and a bad
/// persisted value can't push the grid out of range.
nonisolated struct GridItemSize: RawRepresentable, Equatable, Comparable {
    static let minimum: Double = 120
    static let maximum: Double = 360
    static let step: Double = 40
    static let `default` = GridItemSize(180)

    /// The clamped edge length in points.
    let value: Double

    init(_ value: Double) {
        self.value = Swift.min(Self.maximum, Swift.max(Self.minimum, value))
    }

    /// Defaults persists `RawRepresentable` values via its raw-representable bridge, and
    /// points are whole numbers, so an `Int` raw value round-trips losslessly and stays
    /// clamped on load.
    init?(rawValue: Int) {
        self.init(Double(rawValue))
    }

    var rawValue: Int {
        Int(value.rounded())
    }

    var isAtMinimum: Bool {
        value <= Self.minimum
    }

    var isAtMaximum: Bool {
        value >= Self.maximum
    }

    func steppedUp() -> GridItemSize {
        self + Self.step
    }

    func steppedDown() -> GridItemSize {
        self - Self.step
    }

    static func + (size: GridItemSize, delta: Double) -> GridItemSize {
        GridItemSize(size.value + delta)
    }

    static func - (size: GridItemSize, delta: Double) -> GridItemSize {
        GridItemSize(size.value - delta)
    }

    static func < (lhs: GridItemSize, rhs: GridItemSize) -> Bool {
        lhs.value < rhs.value
    }
}
