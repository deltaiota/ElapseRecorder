import AppKit
import SFSafeSymbols
import SwiftUI
import TranslateKit
import UniformTypeIdentifiers

struct AppSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let runningApplications: [RunningApplication]
    let detectedApps: [AppCaptureSummary]
    let whitelistedBundleIdentifiers: Set<String>
    let defaultCaptureInterval: TimeInterval
    let addAppsToWhitelist: ([WhitelistedAppConfig]) -> Void

    @State private var currentRunningApplications: [AppSelectionCandidate] = []
    @State private var installedApplications: [AppSelectionCandidate] = []
    @State private var chosenFileApplications: [AppSelectionCandidate] = []
    @State private var selectedBundleIdentifiers: Set<String> = []
    @State private var searchText = ""
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List(selection: $selectedBundleIdentifiers) {
                if let importError {
                    Label(importError, systemSymbol: .exclamationmarkTriangle)
                        .foregroundStyle(.orange)
                }

                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.candidates) { candidate in
                            candidateRow(candidate)
                                .tag(candidate.bundleIdentifier)
                        }
                    }
                }
            }
            .overlay(alignment: .center) {
                if sections.isEmpty {
                    ContentUnavailableView(
                        unavailableTitle,
                        systemSymbol: .appBadge,
                        description: Text(unavailableDescription)
                    )
                }
            }
            .navigationTitle("Installed Apps")
            .searchable(text: $searchText, prompt: "Search apps…")
            .toolbar {
                ToolbarItem {
                    Button("Choose App Files…", systemSymbol: .folderBadgePlus) {
                        chooseApplicationFiles()
                    }
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button(TK.Action.cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(addButtonTitle) {
                        addSelectedApps()
                    }
                    .disabled(selectedBundleIdentifiers.isEmpty)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .task {
            installedApplications = await Task.detached(priority: .userInitiated) {
                AppSelectionCandidate.installedApplications()
            }.value
            currentRunningApplications = await MainActor.run {
                AppSelectionCandidate.runningApplications(fallback: runningApplications)
            }
        }
    }

    private func candidateRow(_ candidate: AppSelectionCandidate) -> some View {
        HStack(spacing: 10) {
            AppIconView(icon: candidate.icon)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.displayName)
                    .lineLimit(1)

                Text(candidate.bundleIdentifier)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var sections: [AppSelectionSection] {
        AppSelectionSource.allCases.compactMap { source in
            let candidates = filteredCandidates(for: source)
            guard !candidates.isEmpty else { return nil }
            return AppSelectionSection(source: source, candidates: candidates)
        }
    }

    private func filteredCandidates(for source: AppSelectionSource) -> [AppSelectionCandidate] {
        mergedCandidates
            .filter { $0.primarySource == source }
            .filter { searchText.isEmpty || $0.matches(searchText) }
            .sortedByDisplayName()
    }

    private var mergedCandidates: [AppSelectionCandidate] {
        var candidatesByBundleIdentifier: [String: AppSelectionCandidate] = [:]

        func upsert(_ candidate: AppSelectionCandidate) {
            guard !whitelistedBundleIdentifiers.contains(candidate.bundleIdentifier) else { return }

            if let existing = candidatesByBundleIdentifier[candidate.bundleIdentifier] {
                candidatesByBundleIdentifier[candidate.bundleIdentifier] = existing.merging(candidate)
            } else {
                candidatesByBundleIdentifier[candidate.bundleIdentifier] = candidate
            }
        }

        for candidate in chosenFileApplications {
            upsert(candidate)
        }

        for application in currentRunningApplications {
            upsert(application)
        }

        for application in installedApplications {
            upsert(application)
        }

        for app in detectedApps {
            upsert(.detected(app))
        }

        return Array(candidatesByBundleIdentifier.values)
    }

    private var selectedCandidates: [AppSelectionCandidate] {
        mergedCandidates
            .filter { selectedBundleIdentifiers.contains($0.bundleIdentifier) }
            .sortedByDisplayName()
    }

    private func addSelectedApps() {
        let configs = selectedCandidates.map {
            WhitelistedAppConfig(
                bundleIdentifier: $0.bundleIdentifier,
                displayName: $0.displayName,
                captureInterval: defaultCaptureInterval,
                isEnabled: true
            )
        }

        addAppsToWhitelist(configs)
        dismiss()
    }

    private func importApplications(_ result: Result<[URL], Error>) {
        do {
            let imported = try result.get().compactMap(AppSelectionCandidate.appFile)
            chosenFileApplications = chosenFileApplications.merging(imported)
            selectedBundleIdentifiers.formUnion(imported.map(\.bundleIdentifier))
            importError = imported.isEmpty ? #tk("No usable app bundles were found.") : nil
        } catch {
            importError = error.localizedDescription
        }
    }

    private func chooseApplicationFiles() {
        let panel = NSOpenPanel()
        panel.title = #tk("Choose App Files")
        panel.message = #tk("Choose one or more app bundles to capture.")
        panel.prompt = #tk("Choose")
        panel.directoryURL = Self.defaultApplicationsDirectory
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            importApplications(.success(panel.urls))
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static var defaultApplicationsDirectory: URL {
        FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
            ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
    }

    private var unavailableTitle: String {
        searchText.isEmpty ? #tk("No apps available") : #tk("No matching apps")
    }

    private var unavailableDescription: String {
        searchText.isEmpty
            ? #tk("Choose app files manually if the app you want is not listed.")
            : #tk("Try a different app name or bundle identifier.")
    }

    private var addButtonTitle: String {
        selectedBundleIdentifiers.count == 1
            ? #tk("Add 1 App")
            : #tk("Add \(selectedBundleIdentifiers.count) Apps")
    }

    private var selectionSummary: String {
        selectedBundleIdentifiers.count == 1
            ? #tk("1 app selected")
            : #tk("\(selectedBundleIdentifiers.count) apps selected")
    }
}

private struct AppSelectionSection: Identifiable {
    let source: AppSelectionSource
    let candidates: [AppSelectionCandidate]

    var id: AppSelectionSource {
        source
    }

    var title: String {
        source.sectionTitle
    }
}

private nonisolated struct AppSelectionCandidate: Identifiable, Hashable {
    var id: String {
        bundleIdentifier
    }

    var bundleIdentifier: String
    var displayName: String
    var appURL: URL?
    var sources: Set<AppSelectionSource>

    @MainActor
    var icon: NSImage? {
        InstalledAppIdentity.icon(appURL: appURL)
    }

    var primarySource: AppSelectionSource {
        AppSelectionSource.allCases.first { sources.contains($0) } ?? .detected
    }

    @MainActor
    var sourceItems: [CountSummary.Item] {
        sources.sortedByDisplayOrder().map {
            .init(text: $0.badgeTitle, systemSymbol: $0.systemSymbol)
        }
    }

    @MainActor
    static func running(_ application: RunningApplication) -> Self {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application.bundleIdentifier)
        let identity = InstalledAppIdentity(
            bundleIdentifier: application.bundleIdentifier,
            recordedName: application.displayName,
            appURL: appURL
        )

        return Self(
            bundleIdentifier: application.bundleIdentifier,
            displayName: identity.localizedName,
            appURL: identity.appURL,
            sources: [.running]
        )
    }

    @MainActor
    static func runningApplications(fallback applications: [RunningApplication]) -> [Self] {
        let liveApplications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(runningApplication)
            .merging([])
            .sortedByDisplayName()

        if !liveApplications.isEmpty {
            return liveApplications
        }

        return applications
            .map(running)
            .merging([])
            .sortedByDisplayName()
    }

    @MainActor
    private static func runningApplication(_ application: NSRunningApplication) -> Self? {
        guard let bundleIdentifier = application.bundleIdentifier else { return nil }

        let appURL = application.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let recordedName = application.localizedName ?? bundleIdentifier
        let identity = InstalledAppIdentity(
            bundleIdentifier: bundleIdentifier,
            recordedName: recordedName,
            appURL: appURL
        )

        return Self(
            bundleIdentifier: bundleIdentifier,
            displayName: identity.localizedName,
            appURL: identity.appURL,
            sources: [.running]
        )
    }

    @MainActor
    static func detected(_ app: AppCaptureSummary) -> Self {
        let identity = InstalledAppIdentity(app: app)
        return Self(
            bundleIdentifier: app.bundleIdentifier,
            displayName: identity.localizedName,
            appURL: identity.appURL,
            sources: [.detected]
        )
    }

    nonisolated static func appFile(_ url: URL) -> Self? {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty
        else { return nil }

        return Self(
            bundleIdentifier: bundleIdentifier,
            displayName: InstalledAppIdentity.localizedName(appURL: url) ?? bundleIdentifier,
            appURL: url,
            sources: [.chosenFile]
        )
    }

    nonisolated static func installedApplications() -> [Self] {
        FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask, .systemDomainMask])
            .flatMap(applications(in:))
            .merging([])
            .sortedByDisplayName()
    }

    func merging(_ candidate: Self) -> Self {
        Self(
            bundleIdentifier: bundleIdentifier,
            displayName: bestDisplayName(comparedWith: candidate),
            appURL: appURL ?? candidate.appURL,
            sources: sources.union(candidate.sources)
        )
    }

    func matches(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        return displayName.localizedStandardContains(trimmedQuery)
            || bundleIdentifier.localizedStandardContains(trimmedQuery)
            || (appURL?.path(percentEncoded: false).localizedStandardContains(trimmedQuery) ?? false)
    }

    private func bestDisplayName(comparedWith candidate: Self) -> String {
        if sources.contains(.chosenFile) || sources.contains(.installed) {
            return displayName
        }
        if candidate.sources.contains(.chosenFile) || candidate.sources.contains(.installed) {
            return candidate.displayName
        }
        return displayName.localizedStandardCompare(candidate.displayName) == .orderedAscending
            ? displayName
            : candidate.displayName
    }

    private nonisolated static func applications(in directory: URL) -> [Self] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)),
              let enumerator = FileManager.default.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.isApplicationKey, .isPackageKey, .localizedNameKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "app" }
            .compactMap { url in
                appFile(url)?.withSource(.installed)
            }
    }

    private func withSource(_ source: AppSelectionSource) -> Self {
        Self(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            appURL: appURL,
            sources: [source]
        )
    }
}

private nonisolated enum AppSelectionSource: CaseIterable, Hashable, Equatable {
    case chosenFile
    case running
    case installed
    case detected

    var sectionTitle: String {
        switch self {
        case .chosenFile:
            return #tk("Chosen App Files")
        case .running:
            return #tk("Running Apps")
        case .installed:
            return #tk("Installed Applications")
        case .detected:
            return #tk("Detected Apps")
        }
    }

    var badgeTitle: String {
        switch self {
        case .chosenFile:
            return #tk("Chosen")
        case .running:
            return #tk("Running")
        case .installed:
            return #tk("Installed")
        case .detected:
            return #tk("Detected")
        }
    }

    var systemSymbol: SFSymbol {
        switch self {
        case .chosenFile:
            return .folder
        case .running:
            return .playCircle
        case .installed:
            return .trayAndArrowDown
        case .detected:
            return .appDashed
        }
    }
}

private nonisolated extension Array where Element == AppSelectionCandidate {
    func merging(_ others: [AppSelectionCandidate]) -> [AppSelectionCandidate] {
        var candidatesByBundleIdentifier: [String: AppSelectionCandidate] = [:]

        for candidate in self + others {
            if let existing = candidatesByBundleIdentifier[candidate.bundleIdentifier] {
                candidatesByBundleIdentifier[candidate.bundleIdentifier] = existing.merging(candidate)
            } else {
                candidatesByBundleIdentifier[candidate.bundleIdentifier] = candidate
            }
        }

        return Array(candidatesByBundleIdentifier.values)
    }

    func sortedByDisplayName() -> [AppSelectionCandidate] {
        sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if comparison == .orderedSame {
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
            return comparison == .orderedAscending
        }
    }
}

private nonisolated extension Set where Element == AppSelectionSource {
    func sortedByDisplayOrder() -> [AppSelectionSource] {
        AppSelectionSource.allCases.filter(contains)
    }
}

#Preview {
    AppSelectionSheet(
        runningApplications: [
            RunningApplication(
                bundleIdentifier: "com.apple.TextEdit",
                displayName: "TextEdit",
                processIdentifier: 42
            ),
        ],
        detectedApps: [
            AppCaptureSummary(
                bundleIdentifier: "com.apple.finder",
                displayName: "Finder",
                sessionCount: 3,
                screenshotCount: 48,
                lastCapturedAt: .now
            ),
        ],
        whitelistedBundleIdentifiers: ["com.apple.Safari"],
        defaultCaptureInterval: 5,
        addAppsToWhitelist: { _ in }
    )
}
