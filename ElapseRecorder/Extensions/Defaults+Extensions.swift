import Defaults

nonisolated extension GridItemSize: Defaults.Serializable {}

nonisolated extension Defaults.Keys {
    static let screenshotGridItemSize = Key<GridItemSize>("screenshotGridItemSize", default: .default)
    static let exportFramesPerSecond = Key<Int>("exportFramesPerSecond", default: 12)
}
