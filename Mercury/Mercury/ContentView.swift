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
    @State private var selectedFeedSelection: FeedSelection = .all
    @State private var selectedEntryId: Int64?
    @AppStorage("readingMode") private var readingModeRaw: String = ReadingMode.reader.rawValue
    @AppStorage("showUnreadOnly") private var showUnreadOnly = false
    @State private var unreadPinnedEntryId: Int64?
    @State private var isLoadingEntries = false
    @State private var editorState: FeedEditorState?
    @State private var pendingDeleteFeed: Feed?
    @State private var pendingImportURL: URL?
    @State private var isShowingImportOptions = false
    @State private var replaceOnImport = false
    @State private var forceSiteNameOnImport = false
#if DEBUG
    @State private var isShowingDebugIssues = false
#endif

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
            await loadEntries(for: selectedFeedId, unreadOnly: showUnreadOnly, selectFirst: selectedEntryId == nil)
            await appModel.bootstrapIfNeeded()
            await loadEntries(for: selectedFeedId, unreadOnly: showUnreadOnly, selectFirst: selectedEntryId == nil)
        }
        .task {
            await startAutoSyncLoop()
        }
        .onChange(of: selectedFeedSelection) { _, newSelection in
            unreadPinnedEntryId = nil
            Task {
                await loadEntries(
                    for: newSelection.feedId,
                    unreadOnly: showUnreadOnly,
                    keepEntryId: nil,
                    selectFirst: true
                )
            }
        }
        .onChange(of: showUnreadOnly) { _, unreadOnly in
            unreadPinnedEntryId = nil
            Task {
                await loadEntries(
                    for: selectedFeedId,
                    unreadOnly: unreadOnly,
                    keepEntryId: nil,
                    selectFirst: true
                )
            }
        }
        .onChange(of: selectedEntryId) { oldValue, newValue in
            guard let entry = selectedEntry else { return }
            Task {
                await appModel.markEntryRead(entry)
                if showUnreadOnly, let entryId = entry.id {
                    unreadPinnedEntryId = entryId
                }
                if showUnreadOnly, let oldValue, oldValue != newValue {
                    await loadEntries(
                        for: selectedFeedId,
                        unreadOnly: true,
                        keepEntryId: unreadPinnedEntryId,
                        selectFirst: false
                    )
                }
            }
        }
        .onChange(of: appModel.backgroundDataVersion) { _, _ in
            Task {
                await loadEntries(
                    for: selectedFeedId,
                    unreadOnly: showUnreadOnly,
                    keepEntryId: showUnreadOnly ? unreadPinnedEntryId : nil,
                    selectFirst: selectedEntryId == nil
                )
            }
        }
        .sheet(item: $editorState) { state in
            FeedEditorSheet(
                state: state,
                onCheck: { url in
                    try await appModel.fetchFeedTitle(for: url)
                },
                onSave: { result in
                    try await handleFeedSave(result)
                },
                onError: { message in
                    appModel.reportUserError(title: "Feed Check Failed", message: message)
                }
            )
        }
        .sheet(isPresented: $isShowingImportOptions) {
            ImportOPMLSheet(
                replaceExisting: $replaceOnImport,
                forceSiteNameAsFeedTitle: $forceSiteNameOnImport
            ) {
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
        .alert(
            appModel.taskCenter.latestUserError?.title ?? "Error",
            isPresented: Binding(
                get: { appModel.taskCenter.latestUserError != nil },
                set: { if !$0 { appModel.taskCenter.dismissUserError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.taskCenter.latestUserError?.message ?? "Unknown error.")
        }
#if DEBUG
        .sheet(isPresented: $isShowingDebugIssues) {
            DebugIssuesView()
                .environmentObject(appModel)
        }
#endif
        .toolbar {
#if DEBUG
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingDebugIssues = true
                } label: {
                    Image(systemName: "ladybug")
                }
                .help("Open debug issues")
            }
#endif
        }
    }

    private var sidebar: some View {
        SidebarView(
            feeds: appModel.feedStore.feeds,
            totalUnreadCount: appModel.totalUnreadCount,
            selectedFeed: $selectedFeedSelection,
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
            unreadOnly: $showUnreadOnly,
            showFeedSource: selectedFeedSelection == .all,
            feedTitleByEntryId: appModel.entryStore.entryFeedTitles,
            selectedEntryId: $selectedEntryId,
            onMarkAllRead: {
                Task {
                    await markLoadedEntries(isRead: true)
                }
            },
            onMarkAllUnread: {
                Task {
                    await markLoadedEntries(isRead: false)
                }
            }
        )
    }

    private var detailView: some View {
        ReaderDetailView(
            selectedEntry: selectedEntry,
            readingModeRaw: $readingModeRaw,
            loadReaderHTML: { entry in
                await appModel.readerBuildResult(for: entry, themeId: "default")
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
            if let userErrorLine = userErrorStatusLine {
                Text(userErrorLine)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let activeTask = activeTaskLine {
                Text(activeTask)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                TimelineView(.everyMinute) { timeline in
                    Text("Feeds: \(appModel.feedCount) · Entries: \(appModel.entryCount) · Unread: \(appModel.totalUnreadCount) · Last sync: \(lastSyncDescription(relativeTo: timeline.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var userErrorStatusLine: String? {
        guard let error = appModel.taskCenter.latestUserError else { return nil }
        return "\(error.title): \(error.message)"
    }

    private func lastSyncDescription(relativeTo now: Date) -> String {
        guard let lastSyncAt = appModel.lastSyncAt else {
            return "never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastSyncAt, relativeTo: now)
    }

    private var activeTaskLine: String? {
        guard let task = appModel.taskCenter.tasks.first(where: { $0.state.isTerminal == false }) else {
            return nil
        }

        let progressText: String
        if let progress = task.progress {
            progressText = "\(Int((progress * 100).rounded()))%"
        } else {
            progressText = "--"
        }
        let message = task.message ?? "Running"
        return "\(task.title) · \(progressText) · \(message)"
    }

    private var selectedEntry: Entry? {
        guard let selectedEntryId else { return nil }
        return appModel.entryStore.entries.first { $0.id == selectedEntryId }
    }

    private var selectedFeedId: Int64? {
        selectedFeedSelection.feedId
    }

    private func loadEntries(
        for feedId: Int64?,
        unreadOnly: Bool,
        keepEntryId: Int64? = nil,
        selectFirst: Bool
    ) async {
        isLoadingEntries = true
        await appModel.entryStore.loadAll(for: feedId, unreadOnly: unreadOnly, keepEntryId: keepEntryId)
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
    private func markLoadedEntries(isRead: Bool) async {
        unreadPinnedEntryId = nil
        await appModel.markLoadedEntriesReadState(isRead: isRead)
        await loadEntries(for: selectedFeedId, unreadOnly: showUnreadOnly, keepEntryId: nil, selectFirst: true)
    }

    @MainActor
    private func beginImportFlow() async {
        guard let url = selectOPMLFile() else { return }
        pendingImportURL = url
        replaceOnImport = false
        forceSiteNameOnImport = false
        isShowingImportOptions = true
    }

    @MainActor
    private func confirmImport() async {
        guard let url = pendingImportURL else { return }
        isShowingImportOptions = false

        do {
            try await appModel.importOPML(
                from: url,
                replaceExisting: replaceOnImport,
                forceSiteNameAsFeedTitle: forceSiteNameOnImport
            )
            await reloadAfterFeedChange()
        } catch {
            appModel.reportUserError(title: "Import Failed", message: error.localizedDescription)
        }
    }

    @MainActor
    private func exportOPML() async {
        guard let url = selectOPMLExportURL() else { return }
        do {
            try await appModel.exportOPML(to: url)
        } catch {
            appModel.reportUserError(title: "Export Failed", message: error.localizedDescription)
        }
    }

    @MainActor
    private func handleFeedSave(_ result: FeedEditorResult) async throws {
        switch result {
        case .add(let title, let url):
            try await appModel.addFeed(title: title, feedURL: url, siteURL: nil)
        case .edit(let feed, let title, let url):
            try await appModel.updateFeed(feed, title: title, feedURL: url, siteURL: feed.siteURL)
        }
        await reloadAfterFeedChange()
    }

    @MainActor
    private func deleteFeed(_ feed: Feed) async {
        do {
            try await appModel.deleteFeed(feed)
            await reloadAfterFeedChange(keepSelection: false)
        } catch {
            appModel.reportUserError(title: "Delete Failed", message: error.localizedDescription)
        }
    }

    @MainActor
    private func reloadAfterFeedChange(keepSelection: Bool = true) async {
        await appModel.feedStore.loadAll()
        await appModel.refreshCounts()

        if keepSelection, let selectedFeedId,
           appModel.feedStore.feeds.contains(where: { $0.id == selectedFeedId }) {
            await loadEntries(for: selectedFeedId, unreadOnly: showUnreadOnly, selectFirst: selectedEntryId == nil)
        } else {
            selectedFeedSelection = .all
            await loadEntries(for: selectedFeedId, unreadOnly: showUnreadOnly, selectFirst: true)
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

enum FeedSelection: Hashable {
    case all
    case feed(Int64)

    var feedId: Int64? {
        switch self {
        case .all:
            return nil
        case .feed(let id):
            return id
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
