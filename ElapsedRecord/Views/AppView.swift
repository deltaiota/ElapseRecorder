import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TranslateKit

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        VStack(spacing: 0) {
            testCaptureBar
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
            await store.send(.task).finish()
        }
    }

    private var testCaptureBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(#tk("Capture test"), systemSymbol: .camera)
                .font(.headline)

            TextField(
                #tk("Bundle ID"),
                text: $store.testBundleIdentifier.sending(\.testBundleIdentifierChanged)
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220)

            TextField(
                #tk("Display name"),
                text: $store.testDisplayName.sending(\.testDisplayNameChanged)
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)

            Stepper(
                value: $store.testIntervalSeconds.sending(\.testIntervalSecondsChanged),
                in: 1 ... 3600,
                step: 1
            ) {
                Text(#tk("Every \(Int(store.testIntervalSeconds))s"))
                    .monospacedDigit()
            }
            .frame(width: 120)

            if store.isTestCaptureEnabled {
                Button {
                    store.send(.stopTestCaptureButtonTapped)
                } label: {
                    Label(#tk("Stop"), systemSymbol: .stopCircle)
                }
            } else {
                Button {
                    store.send(.startTestCaptureButtonTapped)
                } label: {
                    Label(#tk("Start"), systemSymbol: .recordCircle)
                }
                .disabled(!store.canStartTestCapture)
            }

            Button {
                store.send(.refreshViewerButtonTapped)
            } label: {
                Label(#tk("Refresh"), systemSymbol: .arrowClockwise)
            }

            Spacer()

            captureStatus

            if !store.captureEngine.recentDiagnostics.isEmpty {
                Menu {
                    ForEach(Array(store.captureEngine.recentDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text(diagnostic)
                    }
                } label: {
                    Label(#tk("Diagnostics"), systemSymbol: .stethoscope)
                }
            }
        }
    }

    @ViewBuilder
    private var captureStatus: some View {
        if let message = store.captureEngine.lastError {
            Label(message, systemSymbol: .exclamationmarkTriangle)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else {
            switch store.captureEngine.permissionStatus {
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
