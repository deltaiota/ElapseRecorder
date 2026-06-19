import AppKit
import Foundation

struct InstalledAppIdentity {
    let bundleIdentifier: String
    let localizedName: String
    let recordedName: String
    let appURL: URL?
    let icon: NSImage?

    init(app: AppCaptureSummary) {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier)

        bundleIdentifier = app.bundleIdentifier
        recordedName = app.displayName
        self.appURL = appURL
        localizedName = Self.localizedName(appURL: appURL) ?? app.displayName
        icon = Self.icon(appURL: appURL)
    }

    private static func localizedName(appURL: URL?) -> String? {
        guard let appURL else { return nil }

        let bundle = Bundle(url: appURL)
        let bundleName = ["CFBundleDisplayName", "CFBundleName"]
            .lazy
            .compactMap { bundle?.object(forInfoDictionaryKey: $0) as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return bundleName ?? FileManager.default.displayName(atPath: appURL.path(percentEncoded: false))
    }

    private static func icon(appURL: URL?) -> NSImage? {
        guard let appURL else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path(percentEncoded: false))
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }
}
