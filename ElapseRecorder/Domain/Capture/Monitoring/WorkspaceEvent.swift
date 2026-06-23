import Foundation

nonisolated enum WorkspaceEvent: Equatable {
    case launched(RunningApplication)
    case terminated(RunningApplication)
    case activated(RunningApplication)
}
