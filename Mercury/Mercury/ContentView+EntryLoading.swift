import SwiftUI

extension ContentView {
    var selectedListEntry: EntryListItem? {
        guard let selectedEntryId else { return nil }
        return appModel.entryStore.entries.first { $0.id == selectedEntryId }
    }

    var selectedFeedId: Int64? {
        selectedFeedSelection.feedId
    }

    var searchDebounceToken: String {
        searchText
    }

    func loadEntries(
        for feedId: Int64?,
        unreadOnly: Bool,
        keepEntryId: Int64? = nil,
        selectFirst: Bool
    ) async {
        isLoadingEntries = true
        isLoadingMoreEntries = false
        let activeFeedId = (searchScope == .allFeeds) ? nil : feedId
        let query = EntryStore.EntryListQuery(
            feedId: activeFeedId,
            unreadOnly: unreadOnly,
            keepEntryId: keepEntryId,
            searchText: searchText
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
        renderedQueryFeedId = activeFeedId
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

        let activeFeedId = (searchScope == .allFeeds) ? nil : selectedFeedId
        let query = EntryStore.EntryListQuery(
            feedId: activeFeedId,
            unreadOnly: showUnreadOnly,
            keepEntryId: showUnreadOnly ? unreadPinnedEntryId : nil,
            searchText: searchText
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
            for: selectedFeedId,
            unreadOnly: showUnreadOnly,
            keepEntryId: nil,
            selectFirst: true
        )
    }

    func startAutoSyncLoop() async {
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
        let searchPart = query.searchText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return [feedPart, unreadPart, searchPart].joined(separator: "|")
    }
}
