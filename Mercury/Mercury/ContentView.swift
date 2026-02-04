//
//  ContentView.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedFeedId: Int64?
    @State private var selectedEntryId: Int64?
    @AppStorage("readingMode") private var readingModeRaw: String = ReadingMode.reader.rawValue
    @State private var isLoadingEntries = false
    @State private var editorState: FeedEditorState?
    @State private var pendingDeleteFeed: Feed?
    @State private var pendingImportURL: URL?
    @State private var isShowingImportOptions = false
    @State private var replaceOnImport = false
    @State private var errorMessage: String?

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
            await loadEntries(for: selectedFeedId, selectFirst: selectedEntryId == nil)
        }
        .task {
            await startAutoSyncLoop()
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
        .sheet(item: $editorState) { state in
            FeedEditorSheet(
                state: state,
                onCheck: { url in
                    try await appModel.fetchFeedTitle(for: url)
                },
                onSave: { result in
                    Task {
                        await handleFeedSave(result)
                    }
                },
                onError: { message in
                    errorMessage = message
                }
            )
        }
        .sheet(isPresented: $isShowingImportOptions) {
            ImportOPMLSheet(replaceExisting: $replaceOnImport) {
                Task {
                    await confirmImport()
                }
            }
        }
        .alert("Delete Feed", isPresented: Binding(
            get: { pendingDeleteFeed != nil },
            set: { if !$0 { pendingDeleteFeed = nil } }
        ), presenting: pendingDeleteFeed) { feed in
            Button("Delete", role: .destructive) {
                Task {
                    await deleteFeed(feed)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { feed in
            Text("Delete \"\(feed.title ?? feed.feedURL)\"? This also removes all associated entries.")
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error.")
        }
    }

    private var sidebar: some View {
        SidebarView(
            feeds: appModel.feedStore.feeds,
            selectedFeedId: $selectedFeedId,
            onAddFeed: {
                editorState = FeedEditorState(mode: .add)
            },
            onImportOPML: {
                Task {
                    await beginImportFlow()
                }
            },
            onSyncNow: {
                Task {
                    await appModel.syncAllFeeds()
                    await loadEntries(for: selectedFeedId, selectFirst: selectedEntryId == nil)
                }
            },
            onExportOPML: {
                Task {
                    await exportOPML()
                }
            },
            onEditFeed: { feed in
                editorState = FeedEditorState(mode: .edit(feed))
            },
            onDeleteFeed: { feed in
                pendingDeleteFeed = feed
            },
            statusView: {
                statusView
            }
        )
    }

    private var entryList: some View {
        EntryListView(
            entries: appModel.entryStore.entries,
            isLoading: isLoadingEntries,
            selectedEntryId: $selectedEntryId
        )
    }

    private var detailView: some View {
        ReaderDetailView(
            selectedEntry: selectedEntry,
            readingModeRaw: $readingModeRaw,
            loadReaderHTML: { entry in
                await appModel.readerHTML(for: entry, themeId: "default")
            }
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch appModel.bootstrapState {
        case .importing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Text("Bootstrap failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .idle, .ready:
            statusForSyncState
        }
    }

    @ViewBuilder
    private var statusForSyncState: some View {
        switch appModel.syncState {
        case .syncing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Text("Sync failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .idle:
            TimelineView(.everyMinute) { timeline in
                Text("Feeds: \(appModel.feedCount) · Entries: \(appModel.entryCount) · Unread: \(appModel.totalUnreadCount) · Last sync: \(lastSyncDescription(relativeTo: timeline.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func lastSyncDescription(relativeTo now: Date) -> String {
        guard let lastSyncAt = appModel.lastSyncAt else {
            return "never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastSyncAt, relativeTo: now)
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

    private func startAutoSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await appModel.autoSyncIfNeeded()
        }
    }

    @MainActor
    private func beginImportFlow() async {
        guard let url = selectOPMLFile() else { return }
        pendingImportURL = url
        replaceOnImport = false
        isShowingImportOptions = true
    }

    @MainActor
    private func confirmImport() async {
        guard let url = pendingImportURL else { return }
        isShowingImportOptions = false

        do {
            try await appModel.importOPML(from: url, replaceExisting: replaceOnImport)
            await reloadAfterFeedChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func exportOPML() async {
        guard let url = selectOPMLExportURL() else { return }
        do {
            try await appModel.exportOPML(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func handleFeedSave(_ result: FeedEditorResult) async {
        do {
            switch result {
            case .add(let title, let url):
                try await appModel.addFeed(title: title, feedURL: url, siteURL: nil)
            case .edit(let feed, let title, let url):
                try await appModel.updateFeed(feed, title: title, feedURL: url, siteURL: feed.siteURL)
            }
            await reloadAfterFeedChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteFeed(_ feed: Feed) async {
        do {
            try await appModel.deleteFeed(feed)
            await reloadAfterFeedChange(keepSelection: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func reloadAfterFeedChange(keepSelection: Bool = true) async {
        await appModel.feedStore.loadAll()
        await appModel.refreshCounts()

        if keepSelection, let selectedFeedId,
           appModel.feedStore.feeds.contains(where: { $0.id == selectedFeedId }) {
            await loadEntries(for: selectedFeedId, selectFirst: selectedEntryId == nil)
        } else {
            selectedFeedId = appModel.feedStore.feeds.first?.id
            await loadEntries(for: selectedFeedId, selectFirst: true)
        }
    }

    @MainActor
    private func selectOPMLFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [opmlContentType]
        panel.title = "Import OPML"

        if let directory = SecurityScopedBookmarkStore.resolveDirectory() {
            panel.directoryURL = directory
        }

        if panel.runModal() == .OK {
            if let url = panel.url {
                SecurityScopedBookmarkStore.saveDirectory(url.deletingLastPathComponent())
            }
            return panel.url
        }

        return nil
    }

    @MainActor
    private func selectOPMLExportURL() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [opmlContentType]
        panel.nameFieldStringValue = "mercury.opml"
        panel.title = "Export OPML"

        if let directory = SecurityScopedBookmarkStore.resolveDirectory() {
            panel.directoryURL = directory
        }

        if panel.runModal() == .OK {
            if let url = panel.url {
                SecurityScopedBookmarkStore.saveDirectory(url.deletingLastPathComponent())
            }
            return panel.url
        }

        return nil
    }

    private var opmlContentType: UTType {
        UTType(filenameExtension: "opml") ?? .xml
    }


}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
