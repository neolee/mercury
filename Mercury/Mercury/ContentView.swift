//
//  ContentView.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appStore: AppStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Mercury")
                .font(.title2)
                .fontWeight(.semibold)
            Text(appStore.isReady ? "Data layer ready" : "Initializing…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
}
