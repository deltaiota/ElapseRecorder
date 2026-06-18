import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct ViewerView: View {
    @Bindable var store: StoreOf<ViewerFeature>

    var body: some View {
        NavigationSplitView {
            appList
        } content: {
            sessionList
        } detail: {
            detailPane
        }
        .navigationTitle(#tk("Elapsed Record"))
        .sheet(item: $store.selectedScreenshot.sending(\.screenshotSelected)) { record in
            ScreenshotDetailView(
                record: record,
                revealInFinder: {
                    store.send(.revealSelectedScreenshotInFinderButtonTapped)
                }
            )
        }
    }

    private var appList: some View {
        List {
            Section {
                ForEach(store.apps) { app in
                    Button {
                        store.send(.appSelected(app.bundleIdentifier))
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(app.displayName)
                                Text("\(app.sessionCount) sessions • \(app.screenshotCount) screenshots")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        } icon: {
                            Image(systemSymbol: .app)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        store.selectedBundleIdentifier == app.bundleIdentifier
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                }
            } header: {
                Label(#tk("Apps"), systemSymbol: .app)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 240)
    }

    private var sessionList: some View {
        List {
            if store.selectedBundleIdentifier != nil {
                Button {
                    store.send(.flatGallerySelected)
                } label: {
                    Label(#tk("All screenshots"), systemSymbol: .photoStack)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    store.isShowingFlatGallery
                        ? Color.accentColor.opacity(0.16)
                        : Color.clear
                )

                Section {
                    ForEach(store.sessions) { session in
                        Button {
                            store.send(.sessionSelected(session.id))
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                                    Text(sessionSummary(session))
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            } icon: {
                                Image(systemSymbol: .clock)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            store.selectedSessionID == session.id
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear
                        )
                    }
                } header: {
                    Label(#tk("Sessions"), systemSymbol: .clock)
                }
            } else {
                ContentUnavailableView(
                    #tk("Choose an app"),
                    systemImage: "app",
                    description: Text(#tk("Captured sessions will appear here."))
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
    }

    @ViewBuilder
    private var detailPane: some View {
        if store.isShowingFlatGallery {
            ScreenshotGrid(
                records: store.flatScreenshots,
                selectScreenshot: { store.send(.screenshotSelected($0)) }
            )
            .navigationTitle(#tk("All screenshots"))
        } else if store.selectedSessionID != nil {
            HStack(spacing: 0) {
                List {
                    Section {
                        ForEach(store.windows) { window in
                            Button {
                                store.send(.windowSelected(window.id))
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(windowTitle(window))
                                        Text("\(window.screenshotCount) screenshots")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                    }
                                } icon: {
                                    Image(systemSymbol: .macwindow)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                store.selectedWindowID == window.id
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear
                            )
                        }
                    } header: {
                        Label(#tk("Windows"), systemSymbol: .macwindow)
                    }
                }
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

                Divider()

                ScreenshotGrid(
                    records: store.windowScreenshots,
                    selectScreenshot: { store.send(.screenshotSelected($0)) }
                )
                .frame(minWidth: 360)
            }
        } else {
            ContentUnavailableView(
                #tk("Choose a session"),
                systemImage: "clock",
                description: Text(#tk("Windows and screenshots will appear here."))
            )
        }
    }

    private func sessionSummary(_ session: CaptureSessionSummary) -> String {
        let duration = Duration.seconds(session.duration)
            .formatted(.time(pattern: .hourMinuteSecond))

        return "\(duration) • \(session.windowCount) windows • \(session.screenshotCount) screenshots"
    }

    private func windowTitle(_ window: WindowCaptureSummary) -> String {
        if let label = window.label, !label.isEmpty {
            return #tk("Window \(window.displayNumber): \(label)")
        }
        return #tk("Window \(window.displayNumber)")
    }
}

private struct ScreenshotGrid: View {
    let records: [ScreenshotRecord]
    let selectScreenshot: (ScreenshotRecord) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(records) { record in
                    Button {
                        selectScreenshot(record)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ScreenshotThumbnailView(record: record)
                                .aspectRatio(16 / 10, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            Text(record.capturedAt, format: .dateTime.hour().minute().second())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    #tk("No screenshots"),
                    systemImage: "photo",
                    description: Text(#tk("Captured frames will appear here."))
                )
            }
        }
    }
}

private struct ScreenshotDetailView: View {
    let record: ScreenshotRecord
    let revealInFinder: () -> Void

    @Dependency(\.imageLoadingClient) private var images
    @State private var image: CGImage?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Rectangle()
                    .fill(.quaternary)

                if let image {
                    Image(nsImage: NSImage(cgImage: image, size: image.displaySize))
                        .resizable()
                        .scaledToFit()
                } else if let errorMessage {
                    ContentUnavailableView(
                        #tk("Could not load image"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 640, minHeight: 420)

            Group {
                Text(record.capturedAt, format: .dateTime.year().month().day().hour().minute().second())
                Text(record.fileURL.path(percentEncoded: false))
                    .font(.caption)
                    .textSelection(.enabled)
                Text("\(record.fileSizeBytes) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(#tk("Reveal in Finder")) {
                    revealInFinder()
                }
            }
        }
        .padding()
        .task(id: record.id) {
            do {
                image = try await images.fullSizeImage(record.fileURL)
                errorMessage = nil
            } catch {
                image = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ScreenshotThumbnailView: View {
    let record: ScreenshotRecord

    @Dependency(\.capturePreferencesClient) private var preferences
    @Dependency(\.thumbnailClient) private var thumbnails
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if let image {
                Image(nsImage: NSImage(cgImage: image, size: image.displaySize))
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemSymbol: .photo)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: record.id) {
            image = nil
            image = try? await thumbnails.thumbnail(
                record.fileURL,
                preferences.thumbnailMaximumPixelSize()
            )
        }
    }
}

private extension CGImage {
    var displaySize: CGSize {
        CGSize(width: width, height: height)
    }
}
