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
}
