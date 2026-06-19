import AppKit
import Foundation

struct InstalledAppIdentity {
    let bundleIdentifier: String
    let localizedName: String
    let recordedName: String
    let appURL: URL?
    let icon: NSImage?

    init(app: AppCaptureSummary) {
        self.init(bundleIdentifier: app.bundleIdentifier, recordedName: app.displayName)
    }

    init(bundleIdentifier: String, recordedName: String, appURL: URL? = nil) {
        let appURL = appURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)

        self.bundleIdentifier = bundleIdentifier
        self.recordedName = recordedName
        self.appURL = appURL
        localizedName = Self.localizedName(appURL: appURL) ?? recordedName
        icon = Self.icon(appURL: appURL)
    }

    nonisolated static func localizedName(appURL: URL?) -> String? {
        guard let appURL else { return nil }

        let bundle = Bundle(url: appURL)
        let bundleName = ["CFBundleDisplayName", "CFBundleName"]
            .lazy
            .compactMap { bundle?.object(forInfoDictionaryKey: $0) as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return bundleName ?? FileManager.default.displayName(atPath: appURL.path(percentEncoded: false))
    }

    static func icon(appURL: URL?) -> NSImage? {
        guard let appURL else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path(percentEncoded: false))
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }
}
