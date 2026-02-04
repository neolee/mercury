//
//  ContentView.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedFeedId: Int64?
    @State private var selectedEntryId: Int64?
    @State private var isLoadingEntries = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            entryList
        } detail: {
            detailView
        }
        .task {
            await appModel.feedStore.loadAll()
            appModel.refreshUnreadTotals()
            if selectedFeedId == nil {
                selectedFeedId = appModel.feedStore.feeds.first?.id
            }
            await loadEntries(for: selectedFeedId, selectFirst: selectedEntryId == nil)
            await appModel.bootstrapIfNeeded()
        }
        .onChange(of: selectedFeedId) { _, newValue in
            Task {
                await loadEntries(for: newValue, selectFirst: true)
            }
        }
        .onChange(of: selectedEntryId) { _, _ in
            guard let entry = selectedEntry else { return }
            Task {
                await appModel.markEntryRead(entry)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedFeedId) {
                ForEach(appModel.feedStore.feeds) { feed in
                    HStack(spacing: 8) {
                        Text(feed.title ?? feed.feedURL)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if feed.unreadCount > 0 {
                            Text("\(feed.unreadCount)")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                    }
                    .tag(feed.id)
                }
            }
            .navigationTitle("Feeds")

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(appModel.isReady ? "Data layer ready" : "Initializing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusView
            }
            .padding(8)
        }
        .frame(minWidth: 220)
    }

    private var entryList: some View {
        List(selection: $selectedEntryId) {
            if isLoadingEntries {
                ProgressView()
            }

            ForEach(appModel.entryStore.entries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    if entry.isRead == false {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                    } else {
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title ?? "(Untitled)")
                            .fontWeight(entry.isRead ? .regular : .semibold)
                            .foregroundStyle(entry.isRead ? .secondary : .primary)
                            .lineLimit(2)
                        if let publishedAt = entry.publishedAt {
                            Text(Self.dateFormatter.string(from: publishedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tag(entry.id)
            }
        }
        .navigationTitle("Entries")
    }

    private var detailView: some View {
        Group {
            if let entry = selectedEntry, let urlString = entry.url, let url = URL(string: urlString) {
                VStack(spacing: 0) {
                    urlBar(urlString)
                    Divider()
                    WebView(url: url)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                    Text("Select an entry to read")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(selectedEntry?.title ?? "Reader")
    }

    @ViewBuilder
    private var statusView: some View {
        switch appModel.bootstrapState {
        case .idle:
            EmptyView()
        case .importing:
            Label("Importing OPML and syncing feeds…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .ready:
            Text("Feeds: \(appModel.feedCount) · Entries: \(appModel.entryCount) · Unread: \(appModel.totalUnreadCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Text("Bootstrap failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var selectedEntry: Entry? {
        guard let selectedEntryId else { return nil }
        return appModel.entryStore.entries.first { $0.id == selectedEntryId }
    }

    private func loadEntries(for feedId: Int64?, selectFirst: Bool) async {
        isLoadingEntries = true
        await appModel.entryStore.loadAll(for: feedId)
        if selectFirst {
            selectedEntryId = appModel.entryStore.entries.first?.id
        }
        isLoadingEntries = false
    }

    private func urlBar(_ urlString: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            Text(urlString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
