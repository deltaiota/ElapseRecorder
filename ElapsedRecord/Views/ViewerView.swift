import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct ViewerView: View {
    @Bindable var store: StoreOf<ViewerFeature>

    var body: some View {
        NavigationSplitView {
            appList()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } content: {
            sessionList()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detailPane()
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

    private func appList() -> some View {
        List(selection: $store.selectedBundleIdentifier.sending(\.appSelected)) {
            ForEach(store.apps) { app in
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
                .tag(app.bundleIdentifier)
            }
        }
    }

    private func sessionList() -> some View {
        List(selection: $store.sessionListSelection.sending(\.sessionListSelectionChanged)) {
            if store.selectedBundleIdentifier != nil {
                if let errorMessage = store.errorMessage {
                    Label(errorMessage, systemSymbol: .exclamationmarkTriangle)
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                Label(#tk("All screenshots"), systemSymbol: .photoStack)
                    .tag(ViewerFeature.State.SessionListSelection.flat)
                    .listRowSeparator(.hidden)

                Section {
                    ForEach(store.sessions) { session in
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
                        .tag(ViewerFeature.State.SessionListSelection.session(id: session.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.send(.deleteSessionButtonTapped(session))
                            } label: {
                                Label(TK.Action.delete, systemSymbol: .trash)
                            }
                            .tint(.red)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.send(.deleteSessionButtonTapped(session))
                            } label: {
                                Text(#tk("Delete Session"))
                            }
                        }
                    }
                } header: {
                    Label(#tk("Sessions"), systemSymbol: .clock)
                }
            }
        }
        .overlay(alignment: .center) {
            if store.selectedBundleIdentifier == nil {
                ContentUnavailableView(
                    #tk("Choose an app"),
                    systemSymbol: .app,
                    description: Text(#tk("Captured sessions will appear here."))
                )
            }
        }
    }

    @ViewBuilder private func detailPane() -> some View {
        if store.isShowingFlatGallery {
            ScreenshotGrid(
                records: store.flatScreenshots,
                selectScreenshot: { store.send(.screenshotSelected($0)) }
            )
            .navigationTitle(#tk("All screenshots"))
        } else if store.selectedSessionID != nil {
            ScreenshotGrid(
                records: store.windowScreenshots,
                selectScreenshot: { store.send(.screenshotSelected($0)) }
            )
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    Picker("Window", selection: $store.selectedWindowID.sending(\.windowSelected)) {
                        Text("All Windows")

                        if !store.windows.isEmpty {
                            Divider()

                            ForEach(store.windows) { window in
                                Button {} label: {
                                    Text(windowTitle(window))

                                    Text("\(window.screenshotCount) screenshots")
                                }
                                .tag(window.id)
                            }
                        }
                    }
                    .padding()
                    .background(.windowBackground)

                    Divider()
                }
            }
        } else {
            ContentUnavailableView(
                #tk("Choose a session"),
                systemSymbol: .clock,
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

#Preview {
    ViewerView(store: .init(initialState: ViewerFeature.State()) {
        ViewerFeature()
    })
    .frame(width: 720, height: 480)
}
