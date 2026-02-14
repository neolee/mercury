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
    @State private var searchText = ""
    @State private var searchScope: EntrySearchScope = .allFeeds
    @State private var preferredSearchScopeForFeed: EntrySearchScope = .currentFeed
    @State private var renderedQueryFeedId: Int64? = nil
    @State private var localKeyMonitor: Any?
    @State private var selectedEntryDetail: Entry?
    @FocusState private var isSearchFieldFocused: Bool
#if DEBUG
    @State private var isShowingDebugIssues = false
#endif

    var body: some View {
        toolbarLayer
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebar
        } content: {
            entryList
        } detail: {
            detailView
        }
    }

    private var taskLayer: some View {
        splitView
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
            .task(id: searchDebounceToken) {
                await debouncedSearchRefresh()
            }
    }

    private var changeLayer: some View {
        taskLayer
            .onChange(of: selectedFeedSelection) { _, newSelection in
                unreadPinnedEntryId = nil
                if newSelection.feedId == nil {
                    searchScope = .allFeeds
                } else {
                    searchScope = preferredSearchScopeForFeed
                }
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
                guard let entryId = newValue else {
                    selectedEntryDetail = nil
                    return
                }
                Task {
                    if let listEntry = selectedListEntry {
                        await appModel.markEntryRead(entryId: listEntry.id, feedId: listEntry.feedId, isRead: listEntry.isRead)
                    }
                    if showUnreadOnly {
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
                    await loadSelectedEntryDetailIfNeeded(for: entryId)
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
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchFieldCommand)) { _ in
                isSearchFieldFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .cancelSearchFieldCommand)) { _ in
                searchText = ""
                isSearchFieldFocused = false
            }
            .onAppear {
                installLocalKeyboardMonitorIfNeeded()
            }
            .onDisappear {
                removeLocalKeyboardMonitor()
            }
            .onExitCommand {
                guard isSearchFieldFocused || searchText.isEmpty == false else { return }
                searchText = ""
                isSearchFieldFocused = false
            }
    }

    private var sheetLayer: some View {
        changeLayer
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
    }

    private var debugLayer: some View {
#if DEBUG
        return AnyView(
            sheetLayer
                .sheet(isPresented: $isShowingDebugIssues) {
                    DebugIssuesView()
                        .environmentObject(appModel)
                }
        )
#else
        return AnyView(sheetLayer)
#endif
    }

    private var toolbarLayer: some View {
        debugLayer
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        TextField("Search entries", text: $searchText)
                            .focused($isSearchFieldFocused)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)

                        Picker("Search Scope", selection: searchScopeBinding) {
                            Text("This Feed")
                                .tag(EntrySearchScope.currentFeed)
                            Text("All Feeds").tag(EntrySearchScope.allFeeds)
                        }
                        .disabled(selectedFeedId == nil)
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }
                }
            }
    }

    private var searchScopeBinding: Binding<EntrySearchScope> {
        Binding(
            get: { selectedFeedId == nil ? .allFeeds : searchScope },
            set: { newValue in
                if selectedFeedId == nil {
                    searchScope = .allFeeds
                    return
                }
                searchScope = newValue
                preferredSearchScopeForFeed = newValue
                Task {
                    await loadEntries(
                        for: selectedFeedId,
                        unreadOnly: showUnreadOnly,
                        keepEntryId: nil,
                        selectFirst: true
                    )
                }
            }
        )
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
            showFeedSource: renderedQueryFeedId == nil,
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
            selectedEntry: selectedEntryDetail,
            readingModeRaw: $readingModeRaw,
            loadReaderHTML: { entry in
                await appModel.readerBuildResult(for: entry, themeId: "default")
            },
            onOpenDebugIssues: openDebugIssuesAction
        )
    }

    private var openDebugIssuesAction: (() -> Void)? {
#if DEBUG
        return { isShowingDebugIssues = true }
#else
        return nil
#endif
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

    private var selectedListEntry: EntryListItem? {
        guard let selectedEntryId else { return nil }
        return appModel.entryStore.entries.first { $0.id == selectedEntryId }
    }

    private var selectedFeedId: Int64? {
        selectedFeedSelection.feedId
    }

    private var effectiveQueryFeedId: Int64? {
        switch searchScope {
        case .currentFeed:
            return selectedFeedId
        case .allFeeds:
            return nil
        }
    }

    private var searchDebounceToken: String {
        searchText
    }

    private func loadEntries(
        for feedId: Int64?,
        unreadOnly: Bool,
        keepEntryId: Int64? = nil,
        selectFirst: Bool
    ) async {
        isLoadingEntries = true
        let activeFeedId = (searchScope == .allFeeds) ? nil : feedId
        await appModel.entryStore.loadAll(
            for: activeFeedId,
            unreadOnly: unreadOnly,
            keepEntryId: keepEntryId,
            searchText: searchText
        )
        renderedQueryFeedId = activeFeedId
        if selectFirst {
            selectedEntryId = appModel.entryStore.entries.first?.id
        }
        if let selectedEntryId {
            await loadSelectedEntryDetailIfNeeded(for: selectedEntryId)
        } else {
            selectedEntryDetail = nil
        }
        isLoadingEntries = false
    }

    private func debouncedSearchRefresh() async {
        unreadPinnedEntryId = nil
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        await loadEntries(
            for: selectedFeedId,
            unreadOnly: showUnreadOnly,
            keepEntryId: nil,
            selectFirst: true
        )
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

    private func loadSelectedEntryDetailIfNeeded(for entryId: Int64) async {
        let detail = await appModel.entryStore.loadEntry(id: entryId)
        if selectedEntryId == entryId {
            selectedEntryDetail = detail
        }
    }

    private func installLocalKeyboardMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                isSearchFieldFocused = true
                return nil
            }

            if event.keyCode == 53, (isSearchFieldFocused || searchText.isEmpty == false) {
                searchText = ""
                isSearchFieldFocused = false
                return nil
            }

            return event
        }
    }

    private func removeLocalKeyboardMonitor() {
        guard let localKeyMonitor else { return }
        NSEvent.removeMonitor(localKeyMonitor)
        self.localKeyMonitor = nil
    }


}

enum EntrySearchScope: Hashable {
    case currentFeed
    case allFeeds
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
