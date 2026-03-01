//
//  ContentView.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import SwiftUI

struct ContentView: View {
    // MARK: - Dependencies

    @EnvironmentObject var appModel: AppModel

    /// Read the active localization bundle directly from `LanguageManager`.
    /// Because this is an `@Observable` object and this property is accessed
    /// inside `body` (via `toolbarLayer`), SwiftUI tracks the dependency and
    /// re-evaluates `ContentView` whenever the bundle changes — without any
    /// extra wrapper view that would disrupt `NavigationSplitView` state storage.
    var bundle: Bundle { LanguageManager.shared.bundle }

    // MARK: - View State

    @State var selectedFeedSelection: FeedSelection = .all
    @State var selectedEntryId: Int64?
    @AppStorage("readingMode") var readingModeRaw: String = ReadingMode.reader.rawValue
    @AppStorage("readerThemePresetID") var readerThemePresetIDRaw: String = ReaderThemePresetID.classic.rawValue
    @AppStorage("readerThemeMode") var readerThemeModeRaw: String = ReaderThemeMode.auto.rawValue
    @AppStorage("readerThemeOverrideFontSize") var readerThemeOverrideFontSize: Double = 0
    @AppStorage("readerThemeOverrideLineHeight") var readerThemeOverrideLineHeight: Double = 0
    @AppStorage("readerThemeOverrideContentWidth") var readerThemeOverrideContentWidth: Double = 0
    @AppStorage("readerThemeOverrideFontFamily") var readerThemeOverrideFontFamilyRaw: String = ReaderThemeFontFamilyOptionID.usePreset.rawValue
    @AppStorage("readerThemeQuickStylePresetID") var readerThemeQuickStylePresetIDRaw: String = ReaderThemeQuickStylePresetID.none.rawValue
    @AppStorage("showUnreadOnly") var showUnreadOnly = false
    @State var unreadPinnedEntryId: Int64?
    @State var isLoadingEntries = false
    @State var isLoadingMoreEntries = false
    @State var entryListHasMore = false
    @State var nextEntryCursor: EntryStore.EntryListCursor?
    @State var entryQueryToken: String = ""
    @State var editorState: FeedEditorState?
    @State var pendingDeleteFeed: Feed?
    @State var pendingImportURL: URL?
    @State var isShowingImportOptions = false
    @State var replaceOnImport = false
    @State var forceSiteNameOnImport = false
    @State var searchText = ""
    @State var searchScope: EntrySearchScope = .allFeeds
    @State var preferredSearchScopeForFeed: EntrySearchScope = .currentFeed
    @State var renderedQueryFeedId: Int64? = nil
    @State var selectedEntryDetail: Entry?
    @State var isSearchFieldFocused: Bool = false
    @State var autoMarkReadTask: Task<Void, Never>? = nil
    @State var autoSelectedEntryId: Int64? = nil
    @State var suppressAutoMarkReadEntryId: Int64? = nil
#if DEBUG
    @State var isShowingDebugIssues = false
#endif

    // MARK: - Root

    var body: some View {
        toolbarLayer
    }

    // MARK: - Layer Composition

    var splitView: some View {
        NavigationSplitView {
            sidebar
        } content: {
            entryList
        } detail: {
            detailView
        }
    }

    var taskLayer: some View {
        splitView
            .task {
                guard await appModel.waitForStartupAutomationReady() else { return }
                await appModel.feedStore.loadAll()
                appModel.refreshUnreadTotals()
                await loadEntries(for: selectedFeedSelection, unreadOnly: showUnreadOnly, selectFirst: selectedEntryId == nil)
                await appModel.bootstrapIfNeeded()
                await loadEntries(for: selectedFeedSelection, unreadOnly: showUnreadOnly, selectFirst: selectedEntryId == nil)
            }
            .task {
                await startAutoSyncLoop()
            }
            .task(id: searchDebounceToken) {
                await debouncedSearchRefresh()
            }
    }

    var changeLayer: some View {
        taskLayer
            .onReceive(NotificationCenter.default.publisher(for: .openDebugIssuesRequested)) { _ in
#if DEBUG
                isShowingDebugIssues = true
#endif
            }
            .onChange(of: selectedFeedSelection) { _, newSelection in
                unreadPinnedEntryId = nil
                if newSelection == .all {
                    searchScope = .allFeeds
                } else {
                    searchScope = preferredSearchScopeForFeed
                }
                Task {
                    await loadEntries(
                        for: newSelection,
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
                        for: selectedFeedSelection,
                        unreadOnly: unreadOnly,
                        keepEntryId: nil,
                        selectFirst: true
                    )
                }
            }
            .onChange(of: selectedEntryId) { oldValue, newValue in
                // Cancel any pending auto mark-read for the previous entry.
                autoMarkReadTask?.cancel()
                autoMarkReadTask = nil
                // A new selection clears the mark-unread suppression flag.
                suppressAutoMarkReadEntryId = nil
                guard let entryId = newValue else {
                    selectedEntryDetail = nil
                    return
                }
                Task {
                    if showUnreadOnly {
                        unreadPinnedEntryId = entryId
                    }
                    if showUnreadOnly, let oldValue, oldValue != newValue {
                        await loadEntries(
                            for: selectedFeedSelection,
                            unreadOnly: true,
                            keepEntryId: unreadPinnedEntryId,
                            selectFirst: false
                        )
                    }
                    await loadSelectedEntryDetailIfNeeded(for: entryId)
                }
                // Only schedule auto mark-read when the user explicitly selected
                // this entry (not an automatic first-entry selection after a reload).
                switch MarkReadPolicy.selectionOutcome(newId: entryId, autoSelectedId: autoSelectedEntryId) {
                case .scheduleAutoMarkRead:
                    // The user navigated away from or past the auto-selected entry,
                    // so clear the guard — future manual returns to that entry should
                    // trigger auto mark-read normally.
                    autoSelectedEntryId = nil
                    scheduleAutoMarkRead(for: entryId)
                case .skipAutoMarkRead:
                    break
                }
            }
            .onChange(of: appModel.backgroundDataVersion) { _, _ in
                Task {
                    await loadEntries(
                        for: selectedFeedSelection,
                        unreadOnly: showUnreadOnly,
                        keepEntryId: showUnreadOnly ? unreadPinnedEntryId : nil,
                        selectFirst: selectedEntryId == nil
                    )
                }
            }
            .onExitCommand {
                guard isSearchFieldFocused || searchText.isEmpty == false else { return }
                clearAndBlurSearchField()
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchFieldCommand)) { _ in
                focusSearchFieldDeferred()
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerFontSizeDecreaseCommand)) { _ in
                decreaseReaderFontSize()
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerFontSizeIncreaseCommand)) { _ in
                increaseReaderFontSize()
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerFontSizeResetCommand)) { _ in
                resetReaderOverrides()
            }
    }

    var sheetLayer: some View {
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
                        appModel.reportUserError(title: String(localized: "Feed Check Failed", bundle: bundle), message: message)
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
            .alert(Text("Delete Feed", bundle: bundle), isPresented: Binding(
                get: { pendingDeleteFeed != nil },
                set: { if !$0 { pendingDeleteFeed = nil } }
            ), presenting: pendingDeleteFeed) { feed in
                Button(role: .destructive, action: { Task { await deleteFeed(feed) } }) { Text("Delete", bundle: bundle) }
                Button(role: .cancel, action: {}) { Text("Cancel", bundle: bundle) }
            } message: { feed in
                Text(String(format: String(localized: "Delete \"%@\"? This also removes all associated entries.", bundle: bundle), feed.title ?? feed.feedURL))
            }
            .alert(
                localizedText(appModel.taskCenter.latestUserError?.title, fallback: "Error"),
                isPresented: Binding(
                    get: { appModel.taskCenter.latestUserError != nil },
                    set: { if !$0 { appModel.taskCenter.dismissUserError() } }
                )
            ) {
                Button(role: .cancel, action: {}) { Text("OK", bundle: bundle) }
            } message: {
                localizedText(appModel.taskCenter.latestUserError?.message, fallback: "Unknown error.")
            }
    }

    var debugLayer: some View {
#if DEBUG
        return AnyView(
            sheetLayer
                .sheet(isPresented: $isShowingDebugIssues) {
                    DebugIssuesView()
                    .environmentObject(appModel.taskCenter)
                }
        )
#else
        return AnyView(sheetLayer)
#endif
    }

    var toolbarLayer: some View {
        debugLayer
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        ToolbarSearchField(
                            text: $searchText,
                            isFocused: $isSearchFieldFocused,
                            placeholder: String(localized: "Search entries", bundle: bundle)
                        )
                            .frame(width: 320)

                        Picker(String(localized: "Search Scope", bundle: bundle), selection: searchScopeBinding) {
                            Text("This Feed", bundle: bundle)
                                .tag(EntrySearchScope.currentFeed)
                            Text("All Feeds", bundle: bundle).tag(EntrySearchScope.allFeeds)
                        }
                        .disabled(selectedFeedSelection == .all)
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }
                }
            }
            .environment(\.localizationBundle, LanguageManager.shared.bundle)
    }

    // MARK: - Core Subviews

    var sidebar: some View {
        SidebarView(
            feeds: appModel.feedStore.feeds,
            totalUnreadCount: appModel.totalUnreadCount,
            totalStarredCount: appModel.totalStarredCount,
            starredUnreadCount: appModel.starredUnreadCount,
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

    var entryList: some View {
        EntryListView(
            entries: appModel.entryStore.entries,
            isLoading: isLoadingEntries,
            isLoadingMore: isLoadingMoreEntries,
            hasMore: entryListHasMore,
            isStarredSelection: selectedFeedSelection == .starred,
            unreadOnly: $showUnreadOnly,
            showFeedSource: renderedQueryFeedId == nil,
            selectedEntryId: $selectedEntryId,
            selectedEntry: selectedListEntry,
            onLoadMore: {
                Task {
                    await loadNextEntriesPage()
                }
            },
            onMarkAllRead: {
                Task {
                    await markLoadedEntries(isRead: true)
                }
            },
            onMarkAllUnread: {
                Task {
                    await markLoadedEntries(isRead: false)
                }
            },
            onMarkSelectedRead: {
                markSelectedEntry(isRead: true)
            },
            onMarkSelectedUnread: {
                markSelectedEntry(isRead: false)
            },
            onToggleStar: { entry in
                Task {
                    await appModel.setEntryStarredState(entryId: entry.id, isStarred: !entry.isStarred)
                }
            }
        )
    }

    var detailView: some View {
        ReaderDetailView(
            selectedEntry: selectedEntryDetail,
            readingModeRaw: $readingModeRaw,
            readerThemePresetIDRaw: $readerThemePresetIDRaw,
            readerThemeModeRaw: $readerThemeModeRaw,
            readerThemeOverrideFontSize: $readerThemeOverrideFontSize,
            readerThemeOverrideLineHeight: $readerThemeOverrideLineHeight,
            readerThemeOverrideContentWidth: $readerThemeOverrideContentWidth,
            readerThemeOverrideFontFamilyRaw: $readerThemeOverrideFontFamilyRaw,
            readerThemeQuickStylePresetIDRaw: $readerThemeQuickStylePresetIDRaw,
            loadReaderHTML: { entry, theme in
                await appModel.readerBuildResult(for: entry, theme: theme)
            },
            onOpenDebugIssues: openDebugIssuesAction
        )
    }

    private func localizedText(_ key: String?, fallback: LocalizedStringKey) -> Text {
        if let key {
            Text(LocalizedStringKey(key), bundle: bundle)
        } else {
            Text(fallback, bundle: bundle)
        }
    }

    var openDebugIssuesAction: (() -> Void)? {
#if DEBUG
        return { isShowingDebugIssues = true }
#else
        return nil
#endif
    }
}

// MARK: - Supporting Types

enum EntrySearchScope: Hashable {
    case currentFeed
    case allFeeds
}

enum FeedSelection: Hashable {
    case all
    case starred
    case feed(Int64)

    var feedId: Int64? {
        switch self {
        case .all:
            return nil
        case .starred:
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
