import SwiftUI

extension ContentView {
    var selectedListEntry: EntryListItem? {
        guard let selectedEntryId else { return nil }
        return appModel.entryStore.entries.first { $0.id == selectedEntryId }
    }

    var selectedFeedId: Int64? {
        if case .feed(let id) = selectedFeedSelection {
            return id
        }
        return nil
    }

    var searchDebounceToken: String {
        searchText
    }

    func loadEntries(
        for selection: FeedSelection,
        unreadOnly: Bool,
        keepEntryId: Int64? = nil,
        selectFirst: Bool
    ) async {
        isLoadingEntries = true
        isLoadingMoreEntries = false
        let query = makeEntryListQuery(
            selection: selection,
            unreadOnly: unreadOnly,
            keepEntryId: keepEntryId,
            searchText: searchText,
            searchScope: searchScope
        )
        let token = makeEntryQueryToken(for: query)
        entryQueryToken = token
        let page = await appModel.entryStore.loadFirstPage(query: query, batchSize: EntryStore.defaultBatchSize)
        guard entryQueryToken == token else {
            isLoadingEntries = false
            return
        }

        entryListHasMore = page.hasMore
        nextEntryCursor = page.nextCursor
        renderedQueryFeedId = query.feedId
        if selectFirst {
            let firstId = appModel.entryStore.entries.first?.id
            // Record that this selection was made automatically so that
            // auto mark-read is not triggered for it.
            autoSelectedEntryId = firstId
            selectedEntryId = firstId
        }
        if let selectedEntryId {
            await loadSelectedEntryDetailIfNeeded(for: selectedEntryId)
        } else {
            selectedEntryDetail = nil
        }
        isLoadingEntries = false
    }

    func loadNextEntriesPage() async {
        guard isLoadingEntries == false else { return }
        guard isLoadingMoreEntries == false else { return }
        guard entryListHasMore else { return }
        guard let cursor = nextEntryCursor else { return }

        let query = makeEntryListQuery(
            selection: selectedFeedSelection,
            unreadOnly: showUnreadOnly,
            keepEntryId: showUnreadOnly ? unreadPinnedEntryId : nil,
            searchText: searchText,
            searchScope: searchScope
        )
        let token = makeEntryQueryToken(for: query)
        guard token == entryQueryToken else { return }

        isLoadingMoreEntries = true
        let page = await appModel.entryStore.loadNextPage(query: query, after: cursor, batchSize: EntryStore.defaultBatchSize)
        guard token == entryQueryToken else {
            isLoadingMoreEntries = false
            return
        }

        entryListHasMore = page.hasMore
        nextEntryCursor = page.nextCursor
        isLoadingMoreEntries = false
    }

    func debouncedSearchRefresh() async {
        unreadPinnedEntryId = nil
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        await loadEntries(
            for: selectedFeedSelection,
            unreadOnly: showUnreadOnly,
            keepEntryId: nil,
            selectFirst: true
        )
    }

    func startAutoSyncLoop() async {
        guard await appModel.waitForStartupAutomationReady() else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await appModel.autoSyncIfNeeded()
        }
    }

    func loadSelectedEntryDetailIfNeeded(for entryId: Int64) async {
        let detail = await appModel.entryStore.loadEntry(id: entryId)
        if selectedEntryId == entryId {
            selectedEntryDetail = detail
        }
    }

    func makeEntryQueryToken(for query: EntryStore.EntryListQuery) -> String {
        let feedPart = query.feedId.map(String.init) ?? "all"
        let unreadPart = query.unreadOnly ? "1" : "0"
        let starredPart = query.starredOnly ? "1" : "0"
        let searchPart = query.searchText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return [feedPart, unreadPart, starredPart, searchPart].joined(separator: "|")
    }

    func makeEntryListQuery(
        selection: FeedSelection,
        unreadOnly: Bool,
        keepEntryId: Int64?,
        searchText: String?,
        searchScope: EntrySearchScope
    ) -> EntryStore.EntryListQuery {
        switch selection {
        case .all:
            return EntryStore.EntryListQuery(
                feedId: nil,
                unreadOnly: unreadOnly,
                starredOnly: false,
                keepEntryId: keepEntryId,
                searchText: searchText
            )
        case .starred:
            return EntryStore.EntryListQuery(
                feedId: nil,
                unreadOnly: unreadOnly,
                starredOnly: true,
                keepEntryId: keepEntryId,
                searchText: searchText
            )
        case .feed(let feedId):
            let resolvedFeedId = (searchScope == .allFeeds) ? nil : feedId
            return EntryStore.EntryListQuery(
                feedId: resolvedFeedId,
                unreadOnly: unreadOnly,
                starredOnly: false,
                keepEntryId: keepEntryId,
                searchText: searchText
            )
        }
    }
}
