//
//  ContentView.swift
//  ElapseRecorder
//
//  Created by KrLite on 2026/6/18.
//

import ComposableArchitecture
import SwiftUI

struct ContentView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        AppView(store: store)
    }
}

#Preview {
    ContentView(
        store: Store(initialState: AppFeature.State()) {
            AppFeature()
        }
    )
    .frame(width: 1080, height: 720)
}
