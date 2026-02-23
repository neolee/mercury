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

    var changeLayer: some View {
        taskLayer
            .onReceive(NotificationCenter.default.publisher(for: .openDebugIssuesRequested)) { _ in
#if DEBUG
                isShowingDebugIssues = true
#endif
            }
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
                Text(LocalizedStringKey(appModel.taskCenter.latestUserError?.title ?? "Error"), bundle: bundle),
                isPresented: Binding(
                    get: { appModel.taskCenter.latestUserError != nil },
                    set: { if !$0 { appModel.taskCenter.dismissUserError() } }
                )
            ) {
                Button(role: .cancel, action: {}) { Text("OK", bundle: bundle) }
            } message: {
                Text(LocalizedStringKey(appModel.taskCenter.latestUserError?.message ?? "Unknown error."), bundle: bundle)
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
                        .disabled(selectedFeedId == nil)
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
            unreadOnly: $showUnreadOnly,
            showFeedSource: renderedQueryFeedId == nil,
            selectedEntryId: $selectedEntryId,
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
