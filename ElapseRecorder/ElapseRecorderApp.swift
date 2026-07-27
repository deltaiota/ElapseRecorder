//
//  ElapseRecorderApp.swift
//  ElapseRecorder
//
//  Created by KrLite on 2026/6/18.
//

import ComposableArchitecture
import SwiftData
import SwiftUI

@main
struct ElapseRecorderApp: App {
    private let sharedModelContainer: ModelContainer
    private let store: StoreOf<AppFeature>

    init() {
        do {
            let modelContainer = try ModelContainer.elapseRecorder()
            sharedModelContainer = modelContainer
            store = Store(initialState: AppFeature.State()) {
                AppFeature()
            } withDependencies: {
                $0.persistenceClient = .live(modelContainer: modelContainer)
            }
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        Window("Elapse Recorder", id: Self.libraryWindowID) {
            ContentView(store: store)
        }
        .modelContainer(sharedModelContainer)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
        }

        Window("About Elapse Recorder", id: Self.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        MenuBarExtra("Elapse Recorder", systemImage: "record.circle") {
            MenuBarView(
                store: store,
                libraryWindowID: Self.libraryWindowID
            )
        }
        .menuBarExtraStyle(.menu)
    }

    private static let libraryWindowID = "library"
    static let aboutWindowID = "about"
}

/// Replaces the standard "About" item so it opens our custom About window.
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Elapse Recorder") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: ElapseRecorderApp.aboutWindowID)
        }
    }
}
