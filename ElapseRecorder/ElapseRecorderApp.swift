//
//  ElapseRecorderApp.swift
//  ElapseRecorder
//
//  Created by KrLite on 2026/6/18.
//

import ComposableArchitecture
import Sparkle
import SwiftData
import SwiftUI

@main
struct ElapseRecorderApp: App {
    private let sharedModelContainer: ModelContainer
    private let store: StoreOf<AppFeature>
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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
                libraryWindowID: Self.libraryWindowID,
                updater: updaterController.updater
            )
        }
        .menuBarExtraStyle(.menu)
    }

    private static let libraryWindowID = "library"
    static let aboutWindowID = "about"
}

/// Native SwiftUI action shared by the standard App menu and the menu-bar menu.
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Elapse Recorder"
    }

    var body: some View {
        Button("About \(appName)") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: ElapseRecorderApp.aboutWindowID)
        }
    }
}
