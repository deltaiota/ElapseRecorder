//
//  ContentView.swift
//  ElapsedRecord
//
//  Created by KrLite on 2026/6/18.
//

import ComposableArchitecture
import SwiftUI

struct ContentView: View {
    let store: StoreOf<ViewerFeature>

    var body: some View {
        ViewerView(store: store)
    }
}

#Preview {
    ContentView(
        store: Store(initialState: ViewerFeature.State()) {
            ViewerFeature()
        }
    )
}
