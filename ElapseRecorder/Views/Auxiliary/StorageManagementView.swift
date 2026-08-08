import AppKit
import ComposableArchitecture
import Defaults
import SFSafeSymbols
import SwiftUI

/// A storage & data-management sheet: total footprint, an integrity sweep, bulk delete of old
/// captures, and the capture location. Uses native form controls rather than custom styling.
struct StorageManagementView: View {
    @Bindable var store: StoreOf<ViewerFeature>
    var scopeBundleIdentifier: String?
    var scopeDisplayName: String?
    var onClose: () -> Void = {}

    @Default(.customCaptureRootPath) private var customCaptureRootPath
    @Default(.retentionMaxAgeEnabled) private var retentionAgeEnabled
    @Default(.retentionMaxAgeDays) private var retentionAgeDays
    @Default(.retentionMaxSizeEnabled) private var retentionSizeEnabled
    @Default(.retentionMaxSizeMegabytes) private var retentionSizeMegabytes
    @Default(.retentionMaxCountEnabled) private var retentionCountEnabled
    @Default(.retentionMaxScreenshotCount) private var retentionMaxCount
    @State private var bulkCutoff = Date()
    @State private var bulkScopeBundleIdentifier: String?
    @State private var didInitBulkScope = false
    @State private var isConfirmingBulkDelete = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                storageSection()
                retentionSection()
                maintenanceSection()
                bulkDeleteSection()
                captureLocationSection()
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 680)
        .onAppear {
            if !didInitBulkScope {
                bulkScopeBundleIdentifier = scopeBundleIdentifier
                didInitBulkScope = true
            }
        }
        .onChange(of: retentionAgeEnabled) { store.send(.enforceRetentionRequested) }
        .onChange(of: retentionAgeDays) { store.send(.enforceRetentionRequested) }
        .onChange(of: retentionSizeEnabled) { store.send(.enforceRetentionRequested) }
        .onChange(of: retentionSizeMegabytes) { store.send(.enforceRetentionRequested) }
        .onChange(of: retentionCountEnabled) { store.send(.enforceRetentionRequested) }
        .onChange(of: retentionMaxCount) { store.send(.enforceRetentionRequested) }
    }

    // MARK: - Storage summary

    @ViewBuilder
    private func storageSection() -> some View {
        Section("Storage") {
            LabeledContent("Total Size", value: totalBytes.formatted(.byteCount(style: .file)))
            LabeledContent("Screenshots", value: totalScreenshots.formatted(.number))
            LabeledContent("Apps", value: store.apps.count.formatted(.number))
        }
    }

    private var totalBytes: Int {
        store.apps.reduce(0) { $0 + $1.sizeBytes }
    }

    private var totalScreenshots: Int {
        store.apps.reduce(0) { $0 + $1.screenshotCount }
    }

    // MARK: - Retention

    @ViewBuilder
    private func retentionSection() -> some View {
        Section {
            Toggle(isOn: $retentionAgeEnabled) {
                Text("Delete captures older than")
            }
            if retentionAgeEnabled {
                Stepper(value: $retentionAgeDays, in: 1 ... 3650) {
                    Text("\(retentionAgeDays) days")
                        .monospacedDigit()
                }
            }

            Toggle(isOn: $retentionSizeEnabled) {
                Text("Limit total size")
            }
            if retentionSizeEnabled {
                HStack {
                    TextField("Size", value: $retentionSizeMegabytes, format: .number)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("MB")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $retentionCountEnabled) {
                Text("Limit screenshot count")
            }
            if retentionCountEnabled {
                HStack {
                    TextField("Count", value: $retentionMaxCount, format: .number)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("screenshots")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if store.isEnforcingRetention {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Apply Now") {
                    store.send(.enforceRetentionRequested)
                }
                .disabled(!isAnyRetentionLimitEnabled || store.isEnforcingRetention)
            }
        } header: {
            Text("Retention")
        } footer: {
            Text("Oldest ended sessions are removed first to satisfy these limits. Recording sessions are never deleted. Runs automatically after each session ends.")
        }
    }

    private var isAnyRetentionLimitEnabled: Bool {
        retentionAgeEnabled || retentionSizeEnabled || retentionCountEnabled
    }

    // MARK: - Integrity sweep

    // MARK: - Maintenance

    @ViewBuilder
    private func maintenanceSection() -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Integrity Sweep")
                    Text("Remove database entries whose files are missing and delete capture files no longer referenced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if store.isRunningStorageMaintenance {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run") {
                        store.send(.runIntegritySweepButtonTapped)
                    }
                }
            }

            if let result = store.storageIntegrityResult {
                Text(integrityResultText(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Maintenance")
        }
    }

    private func integrityResultText(_ result: StorageIntegrityResult) -> String {
        if result.isEmpty {
            return String(localized: "No issues found.")
        }
        let reclaimed = result.reclaimedBytes.formatted(.byteCount(style: .file))
        return String(
            localized: "Removed \(result.removedRecordCount) records and \(result.removedFileCount) files · reclaimed \(reclaimed)."
        )
    }

    // MARK: - Bulk delete

    @ViewBuilder
    private func bulkDeleteSection() -> some View {
        Section("Delete Old Captures") {
            DatePicker(
                "Delete captures before",
                selection: $bulkCutoff,
                displayedComponents: [.date]
            )

            if !store.apps.isEmpty {
                Picker("Scope", selection: $bulkScopeBundleIdentifier) {
                    Text("All Apps").tag(String?.none)
                    ForEach(store.apps) { app in
                        Text(app.displayName).tag(String?.some(app.bundleIdentifier))
                    }
                }
            }

            Button(role: .destructive) {
                isConfirmingBulkDelete = true
            } label: {
                Text("Delete Captures Before \(bulkCutoff.formatted(date: .abbreviated, time: .omitted))")
            }
            .disabled(store.isRunningStorageMaintenance)
            .confirmationDialog(
                Text("Delete these captures?"),
                isPresented: $isConfirmingBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    store.send(.bulkDeleteRequested(
                        before: startOfDay(bulkCutoff),
                        bundleIdentifier: bulkScopeBundleIdentifier
                    ))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sessions started before this date will be permanently deleted, along with their screenshots.")
            }
        }
    }

    private func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    // MARK: - Capture location

    @ViewBuilder
    private func captureLocationSection() -> some View {
        Section {
            LabeledContent("Location") {
                Text(currentLocationDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Choose…") { chooseCaptureLocation() }
                if !customCaptureRootPath.isEmpty {
                    Button("Reset to Default") { customCaptureRootPath = "" }
                }
            }
        } header: {
            Text("Capture Location")
        } footer: {
            Text("New captures are saved here. Existing captures stay where they were saved.")
        }
    }

    private var currentLocationDescription: String {
        if customCaptureRootPath.isEmpty {
            return String(localized: "Default (Application Support)")
        }
        return customCaptureRootPath
    }

    private func chooseCaptureLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            customCaptureRootPath = url.path(percentEncoded: false)
        }
    }
}
