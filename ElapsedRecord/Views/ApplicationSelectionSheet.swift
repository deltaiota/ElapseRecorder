import AppKit
import SFSafeSymbols
import SwiftUI
import TranslateKit
import UniformTypeIdentifiers

struct ApplicationSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let disabledBundleIdentifiers: Set<String>
    let defaultCaptureInterval: TimeInterval
    let whitelistApplications: ([WhitelistedAppConfig]) -> Void

    @State private var currentRunningApplications: [ApplicationSelectionCandidate] = []
    @State private var installedApplications: [ApplicationSelectionCandidate] = []
    @State private var chosenFileApplications: [ApplicationSelectionCandidate] = []
    @State private var selectedBundleIdentifiers: Set<String> = []
    @State private var searchText = ""
    @State private var isImportingApplications = false
    @State private var importError: String?
    @State private var refreshRunningApplicationsButtonAnimationTrigger: Int = 0

    var body: some View {
        NavigationStack {
            List(selection: selectionBinding) {
                if let importError {
                    Label(importError, systemSymbol: .exclamationmarkTriangle)
                        .foregroundStyle(.orange)
                }

                ForEach(sections) { section in
                    Section {
                        ForEach(section.candidates) { candidate in
                            candidateRow(candidate)
                                .tag(candidate.bundleIdentifier)
                                .disabled(isDisabled(candidate))
                        }
                    } header: {
                        switch section.source {
                        case .running:
                            HStack {
                                Text(section.title)

                                Button {
                                    refreshRunningApplications()
                                    refreshRunningApplicationsButtonAnimationTrigger += 1
                                } label: {
                                    Image(systemSymbol: .arrowCounterclockwise)
                                        .symbolEffect(.rotate, options: .speed(8), value: refreshRunningApplicationsButtonAnimationTrigger)
                                }
                                .buttonStyle(.plain)
                            }
                        default: Text(section.title)
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
            .navigationTitle("Whitelist Applications")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    TextField("Search Applications", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Text(selectionSummary)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.bar)
            }
            .toolbar {
                ToolbarItem {
                    Button("Choose App Files…", systemSymbol: .folderBadgePlus) {
                        isImportingApplications = true
                    }
                    .controlSize(.large)
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button(TK.Action.cancel) {
                        dismiss()
                    }
                    .controlSize(.large)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(addButtonTitle) {
                        whitelistSelectedApplications()
                    }
                    .controlSize(.large)
                    .disabled(selectableSelectedBundleIdentifiers.isEmpty)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .task {
            refreshRunningApplications()
            installedApplications = await Task.detached(priority: .userInitiated) {
                ApplicationSelectionCandidate.installedApplications()
            }.value
        }
        .fileImporter(
            isPresented: $isImportingApplications,
            allowedContentTypes: [.applicationBundle],
            allowsMultipleSelection: true
        ) { result in
            importApplications(result)
        }
        .fileDialogDefaultDirectory(Self.defaultApplicationsDirectory)
    }

    @ViewBuilder
    private func candidateRow(_ candidate: ApplicationSelectionCandidate) -> some View {
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

            Spacer()

            if isDisabled(candidate) {
                Label("Added", systemSymbol: .checkmarkCircle)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var sections: [ApplicationSelectionSection] {
        ApplicationSelectionSource.allCases.compactMap { source in
            let candidates = filteredCandidates(for: source)
            guard !candidates.isEmpty else { return nil }
            return ApplicationSelectionSection(source: source, candidates: candidates)
        }
    }

    private func filteredCandidates(for source: ApplicationSelectionSource) -> [ApplicationSelectionCandidate] {
        mergedCandidates
            .filter { $0.primarySource == source }
            .filter { searchText.isEmpty || $0.matches(searchText) }
            .sortedByDisplayName()
    }

    private var mergedCandidates: [ApplicationSelectionCandidate] {
        var candidatesByBundleIdentifier: [String: ApplicationSelectionCandidate] = [:]

        func upsert(_ candidate: ApplicationSelectionCandidate) {
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

        return Array(candidatesByBundleIdentifier.values)
    }

    private var selectionBinding: Binding<Set<String>> {
        Binding {
            selectedBundleIdentifiers
        } set: { bundleIdentifiers in
            selectedBundleIdentifiers = bundleIdentifiers.subtracting(disabledBundleIdentifiers)
        }
    }

    private var selectableSelectedBundleIdentifiers: Set<String> {
        selectedBundleIdentifiers.subtracting(disabledBundleIdentifiers)
    }

    private var selectedCandidates: [ApplicationSelectionCandidate] {
        mergedCandidates
            .filter { selectableSelectedBundleIdentifiers.contains($0.bundleIdentifier) }
            .sortedByDisplayName()
    }

    private func whitelistSelectedApplications() {
        let configs = selectedCandidates.map {
            WhitelistedAppConfig(
                bundleIdentifier: $0.bundleIdentifier,
                displayName: $0.displayName,
                captureInterval: defaultCaptureInterval,
                isEnabled: true
            )
        }

        whitelistApplications(configs)
        dismiss()
    }

    private func importApplications(_ result: Result<[URL], Error>) {
        do {
            let imported = try result.get().compactMap(ApplicationSelectionCandidate.appFile)
            chosenFileApplications = chosenFileApplications.merging(imported)
            selectedBundleIdentifiers.formUnion(
                imported
                    .map(\.bundleIdentifier)
                    .filter { !disabledBundleIdentifiers.contains($0) }
            )
            importError = imported.isEmpty ? #tk("No usable app bundles were found.") : nil
        } catch {
            importError = error.localizedDescription
        }
    }

    private func refreshRunningApplications() {
        currentRunningApplications = ApplicationSelectionCandidate.runningApplications()
    }

    private func isDisabled(_ candidate: ApplicationSelectionCandidate) -> Bool {
        disabledBundleIdentifiers.contains(candidate.bundleIdentifier)
    }

    private static var defaultApplicationsDirectory: URL {
        FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
            ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
    }

    private var unavailableTitle: String {
        searchText.isEmpty ? #tk("No applications available") : #tk("No matching applications")
    }

    private var unavailableDescription: String {
        searchText.isEmpty
            ? #tk("Choose application files manually if the application you want is not listed.")
            : #tk("Try a different application name or bundle identifier.")
    }

    private var addButtonTitle: String {
        #tk("Whitelist \(selectableSelectedBundleIdentifiers.count) Apps")
    }

    private var selectionSummary: String {
        #tk("\(selectableSelectedBundleIdentifiers.count) applications selected")
    }
}

private struct ApplicationSelectionSection: Identifiable {
    let source: ApplicationSelectionSource
    let candidates: [ApplicationSelectionCandidate]

    var id: ApplicationSelectionSource {
        source
    }

    var title: String {
        source.sectionTitle
    }
}

private nonisolated struct ApplicationSelectionCandidate: Identifiable, Hashable {
    var id: String {
        bundleIdentifier
    }

    var bundleIdentifier: String
    var displayName: String
    var appURL: URL?
    var sources: Set<ApplicationSelectionSource>

    @MainActor
    var icon: NSImage? {
        InstalledAppIdentity.icon(appURL: appURL)
    }

    var primarySource: ApplicationSelectionSource {
        ApplicationSelectionSource.allCases.first { sources.contains($0) } ?? .installed
    }

    @MainActor
    var sourceItems: [CountSummary.Item] {
        sources.sortedByDisplayOrder().map {
            .init(text: $0.badgeTitle, systemSymbol: $0.systemSymbol)
        }
    }

    @MainActor
    static func runningApplications() -> [Self] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(runningApplication)
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

    private func withSource(_ source: ApplicationSelectionSource) -> Self {
        Self(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            appURL: appURL,
            sources: [source]
        )
    }
}

private nonisolated enum ApplicationSelectionSource: CaseIterable, Hashable, Equatable {
    case chosenFile
    case running
    case installed

    var sectionTitle: String {
        switch self {
        case .chosenFile:
            return #tk("Chosen Applications")
        case .running:
            return #tk("Running Applications")
        case .installed:
            return #tk("Installed Applications")
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
        }
    }
}

private nonisolated extension Array where Element == ApplicationSelectionCandidate {
    func merging(_ others: [ApplicationSelectionCandidate]) -> [ApplicationSelectionCandidate] {
        var candidatesByBundleIdentifier: [String: ApplicationSelectionCandidate] = [:]

        for candidate in self + others {
            if let existing = candidatesByBundleIdentifier[candidate.bundleIdentifier] {
                candidatesByBundleIdentifier[candidate.bundleIdentifier] = existing.merging(candidate)
            } else {
                candidatesByBundleIdentifier[candidate.bundleIdentifier] = candidate
            }
        }

        return Array(candidatesByBundleIdentifier.values)
    }

    func sortedByDisplayName() -> [ApplicationSelectionCandidate] {
        sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if comparison == .orderedSame {
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
            return comparison == .orderedAscending
        }
    }
}

private nonisolated extension Set where Element == ApplicationSelectionSource {
    func sortedByDisplayOrder() -> [ApplicationSelectionSource] {
        ApplicationSelectionSource.allCases.filter(contains)
    }
}

#Preview {
    ApplicationSelectionSheet(
        disabledBundleIdentifiers: ["com.apple.Safari", "com.apple.finder"],
        defaultCaptureInterval: 5,
        whitelistApplications: { _ in }
    )
}
