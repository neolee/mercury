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
            statusView
        }
        .padding()
        .task {
            await appStore.bootstrapIfNeeded()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch appStore.bootstrapState {
        case .idle:
            EmptyView()
        case .importing:
            Label("Importing OPML and syncing feeds…", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .ready:
            Text("Feeds: \(appStore.feedCount) · Entries: \(appStore.entryCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Text("Bootstrap failed: \(message)")
                .font(.subheadline)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
}
