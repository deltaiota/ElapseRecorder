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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema.elapsedRecord
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: Store(initialState: AppFeature.State()) {
                    AppFeature()
                } withDependencies: {
                    $0.persistenceClient = .live(modelContainer: sharedModelContainer)
                }
            )
        }
        .modelContainer(sharedModelContainer)
    }
}
