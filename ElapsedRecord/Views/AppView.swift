import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct AppView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            VStack(spacing: 0) {
                testCaptureBar(viewStore)
                    .padding()
                    .background(.regularMaterial)

                Divider()

                ViewerView(
                    store: store.scope(
                        state: \.viewer,
                        action: \.viewer
                    )
                )
            }
            .task {
                await viewStore.send(.task).finish()
            }
        }
    }

    private func testCaptureBar(_ viewStore: ViewStoreOf<AppFeature>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Label(#tk("Capture test"), systemSymbol: .camera)
                .font(.headline)

            TextField(
                #tk("Bundle ID"),
                text: viewStore.binding(
                    get: \.testBundleIdentifier,
                    send: AppFeature.Action.testBundleIdentifierChanged
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220)

            TextField(
                #tk("Display name"),
                text: viewStore.binding(
                    get: \.testDisplayName,
                    send: AppFeature.Action.testDisplayNameChanged
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)

            Stepper(
                value: viewStore.binding(
                    get: \.testIntervalSeconds,
                    send: AppFeature.Action.testIntervalSecondsChanged
                ),
                in: 1 ... 3600,
                step: 1
            ) {
                Text(#tk("Every \(Int(viewStore.testIntervalSeconds))s"))
                    .monospacedDigit()
            }
            .frame(width: 120)

            if viewStore.isTestCaptureEnabled {
                Button {
                    viewStore.send(.stopTestCaptureButtonTapped)
                } label: {
                    Label(#tk("Stop"), systemSymbol: .stopCircle)
                }
            } else {
                Button {
                    viewStore.send(.startTestCaptureButtonTapped)
                } label: {
                    Label(#tk("Start"), systemSymbol: .recordCircle)
                }
                .disabled(!viewStore.canStartTestCapture)
            }

            Button {
                viewStore.send(.refreshViewerButtonTapped)
            } label: {
                Label(#tk("Refresh"), systemSymbol: .arrowClockwise)
            }

            Spacer()

            captureStatus(viewStore)
        }
    }

    @ViewBuilder
    private func captureStatus(_ viewStore: ViewStoreOf<AppFeature>) -> some View {
        if let message = viewStore.captureEngine.lastError {
            Label(message, systemSymbol: .exclamationmarkTriangle)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else {
            switch viewStore.captureEngine.permissionStatus {
            case .authorized:
                Label(#tk("Ready"), systemSymbol: .checkmarkCircle)
                    .foregroundStyle(.secondary)
            case .notDetermined:
                Label(#tk("Permission not requested"), systemSymbol: .questionmarkCircle)
                    .foregroundStyle(.secondary)
            case .denied:
                Label(#tk("Screen Recording denied"), systemSymbol: .exclamationmarkTriangle)
                    .foregroundStyle(.orange)
            }
        }
    }
}
