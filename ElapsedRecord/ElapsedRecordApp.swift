//
//  ElapsedRecordApp.swift
//  ElapsedRecord
//
//  Created by KrLite on 2026/6/18.
//

import ComposableArchitecture
import SwiftData
import SwiftUI

@main
struct ElapsedRecordApp: App {
    private let sharedModelContainer: ModelContainer
    private let store: StoreOf<AppFeature>

    init() {
        let schema = Schema.elapsedRecord
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
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
        WindowGroup("Elapsed Record", id: Self.libraryWindowID) {
            ContentView(store: store)
        }
        .modelContainer(sharedModelContainer)

        MenuBarExtra("Elapsed Record", systemImage: "record.circle") {
            MenuBarView(
                store: store,
                libraryWindowID: Self.libraryWindowID
            )
        }
        .menuBarExtraStyle(.menu)
    }

    private static let libraryWindowID = "library"
}
