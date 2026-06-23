import Defaults

/// `GridItemSize` is `RawRepresentable` over `Int`, so Defaults can serialize it via its
/// built-in raw-representable bridge; the conformance lives here to keep the Domain type
/// free of any Defaults dependency.
nonisolated extension GridItemSize: Defaults.Serializable {}

nonisolated extension Defaults.Keys {
    static let screenshotGridItemSize = Key<GridItemSize>("screenshotGridItemSize", default: .default)
}
