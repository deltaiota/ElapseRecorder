//
//  ElapseRecorderApp.swift
//  ElapseRecorder
//
//  Created by KrLite on 2026/6/18.
//

import ComposableArchitecture
import Sparkle
import SwiftUI

@main
struct ElapseRecorderApp: App {
    private let store: StoreOf<AppFeature>
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        do {
            let isTesting = Self.isTesting
            let backend = try BackendContainer(
                databaseURL: isTesting ? Self.testDatabaseURL : FileStoragePaths.databaseURL(),
                legacyStoreURL: isTesting ? nil : FileStoragePaths.legacyStoreURL()
            )
            let appStore = Store(initialState: AppFeature.State()) {
                AppFeature()
            } withDependencies: {
                $0.persistenceClient = backend.persistence
                $0.storageCoordinatorClient = backend.storage
                $0.recordingServiceClient = backend.recording
            }
            store = appStore
            if !isTesting {
                appStore.send(.task)
            }
        } catch {
            fatalError("Could not create V2 database: \(error)")
        }
    }

    var body: some Scene {
        Window("Elapse Recorder", id: Self.libraryWindowID) {
            ContentView(store: store)
        }
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
    private static var isTesting: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static var testDatabaseURL: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ElapseRecorder-Tests-\(ProcessInfo.processInfo.processIdentifier).sqlite")
    }

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
