import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct ViewerView: View {
    let store: StoreOf<ViewerFeature>

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationSplitView {
                appList(viewStore)
            } content: {
                sessionList(viewStore)
            } detail: {
                detailPane(viewStore)
            }
            .navigationTitle(#tk("Elapsed Record"))
            .task {
                await viewStore.send(.task).finish()
            }
        }
    }

    private func appList(_ viewStore: ViewStoreOf<ViewerFeature>) -> some View {
        List(
            selection: viewStore.binding(
                get: \.selectedBundleIdentifier,
                send: ViewerFeature.Action.appSelected
            )
        ) {
            Section {
                ForEach(viewStore.apps) { app in
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
                    .tag(app.bundleIdentifier as String?)
                }
            } header: {
                Label(#tk("Apps"), systemSymbol: .app)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 240)
    }

    private func sessionList(_ viewStore: ViewStoreOf<ViewerFeature>) -> some View {
        List(
            selection: viewStore.binding(
                get: \.selectedSessionID,
                send: ViewerFeature.Action.sessionSelected
            )
        ) {
            if viewStore.selectedBundleIdentifier != nil {
                Button {
                    viewStore.send(.flatGallerySelected)
                } label: {
                    Label(#tk("All screenshots"), systemSymbol: .photoStack)
                }

                Section {
                    ForEach(viewStore.sessions) { session in
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
                        .tag(session.id as UUID?)
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
    private func detailPane(_ viewStore: ViewStoreOf<ViewerFeature>) -> some View {
        if viewStore.isShowingFlatGallery {
            ScreenshotGrid(records: viewStore.flatScreenshots)
                .navigationTitle(#tk("All screenshots"))
        } else if viewStore.selectedSessionID != nil {
            HSplitView {
                List(
                    selection: viewStore.binding(
                        get: \.selectedWindowID,
                        send: ViewerFeature.Action.windowSelected
                    )
                ) {
                    Section {
                        ForEach(viewStore.windows) { window in
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
                            .tag(window.id as UUID?)
                        }
                    } header: {
                        Label(#tk("Windows"), systemSymbol: .macwindow)
                    }
                }
                .frame(minWidth: 220)

                ScreenshotGrid(records: viewStore.windowScreenshots)
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

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        ScreenshotThumbnailView(record: record)
                            .aspectRatio(16 / 10, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text(record.capturedAt, format: .dateTime.hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                Image(nsImage: NSImage(cgImage: image, size: .zero))
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemSymbol: .photo)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: record.id) {
            image = try? await thumbnails.thumbnail(
                record.fileURL,
                preferences.thumbnailMaximumPixelSize()
            )
        }
    }
}
