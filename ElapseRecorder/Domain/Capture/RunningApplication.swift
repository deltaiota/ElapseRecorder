import Foundation

nonisolated struct RunningApplication: Equatable, Identifiable {
    var id: String {
        bundleIdentifier
    }

    var bundleIdentifier: String
    var displayName: String
    var processIdentifier: pid_t
}
