import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    // MARK: - Per-entry read-state helpers

    /// Schedules a 3-second debounced auto mark-read for the given entry.
    /// The task is stored in `autoMarkReadTask`; cancelling it prevents the mark.
    func scheduleAutoMarkRead(for entryId: Int64) {
        autoMarkReadTask?.cancel()
        autoMarkReadTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard let listEntry = selectedListEntry else { return }
            guard MarkReadPolicy.shouldExecuteAutoMarkRead(
                targetEntryId: entryId,
                currentSelectedEntryId: selectedEntryId,
                suppressedEntryId: suppressAutoMarkReadEntryId,
                isAlreadyRead: listEntry.isRead
            ) else { return }
            await appModel.setEntryReadState(entryId: entryId, feedId: listEntry.feedId, isRead: true)
        }
    }

    /// Immediately marks the currently selected entry as read or unread.
    /// Marking unread also cancels any pending auto mark-read for this entry.
    func markSelectedEntry(isRead: Bool) {
        guard let listEntry = selectedListEntry else { return }
        if !isRead {
            suppressAutoMarkReadEntryId = listEntry.id
            autoMarkReadTask?.cancel()
            autoMarkReadTask = nil
        }
        Task {
            await appModel.setEntryReadState(entryId: listEntry.id, feedId: listEntry.feedId, isRead: isRead)
        }
    }

    // MARK: - Batch read-state helpers

    @MainActor
    func markLoadedEntries(isRead: Bool) async {
        unreadPinnedEntryId = nil
        let query = makeEntryListQuery(
            selection: selectedFeedSelection,
            unreadOnly: showUnreadOnly,
            keepEntryId: nil,
            searchText: searchText,
            searchScope: searchScope
        )
        await appModel.markEntriesReadState(query: query, isRead: isRead)
        await loadEntries(for: selectedFeedSelection, unreadOnly: showUnreadOnly, keepEntryId: nil, selectFirst: true)
    }

    @MainActor
    func handleToggleStar(for entry: EntryListItem) async {
        let targetIsStarred = !entry.isStarred
        let shouldApplyHandoff = shouldApplyStarredSelectionHandoff(
            currentSelection: selectedFeedSelection,
            selectedEntryId: selectedEntryId,
            entry: entry,
            targetIsStarred: targetIsStarred
        )

        let fallbackEntryId: Int64?
        if shouldApplyHandoff {
            fallbackEntryId = makeStarredSelectionFallbackEntryId(
                entryIDs: appModel.entryStore.entries.map(\.id),
                removingEntryId: entry.id,
                selectedEntryId: selectedEntryId
            )
        } else {
            fallbackEntryId = nil
        }

        let succeeded = await appModel.setEntryStarredState(entryId: entry.id, isStarred: targetIsStarred)
        guard succeeded else { return }
        guard shouldApplyHandoff else { return }

        autoSelectedEntryId = fallbackEntryId
        selectedEntryId = fallbackEntryId
        if fallbackEntryId == nil {
            selectedEntryDetail = nil
            unreadPinnedEntryId = nil
        }
    }

    func shouldApplyStarredSelectionHandoff(
        currentSelection: FeedSelection,
        selectedEntryId: Int64?,
        entry: EntryListItem,
        targetIsStarred: Bool
    ) -> Bool {
        currentSelection == .starred
            && selectedEntryId == entry.id
            && entry.isStarred
            && targetIsStarred == false
    }

    func makeStarredSelectionFallbackEntryId(
        entryIDs: [Int64],
        removingEntryId: Int64,
        selectedEntryId: Int64?
    ) -> Int64? {
        guard selectedEntryId == removingEntryId else { return nil }
        guard let index = entryIDs.firstIndex(of: removingEntryId) else { return nil }

        let nextIndex = index + 1
        if entryIDs.indices.contains(nextIndex) {
            return entryIDs[nextIndex]
        }
        if index > 0 {
            return entryIDs[index - 1]
        }
        return nil
    }

    @MainActor
    func beginImportFlow() async {
        guard let url = selectOPMLFile() else { return }
        pendingImportURL = url
        replaceOnImport = false
        forceSiteNameOnImport = false
        isShowingImportOptions = true
    }

    @MainActor
    func confirmImport() async {
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
            appModel.reportUserError(title: String(localized: "Import Failed", bundle: bundle), message: error.localizedDescription)
        }
    }

    @MainActor
    func exportOPML() async {
        guard let url = selectOPMLExportURL() else { return }
        do {
            try await appModel.exportOPML(to: url)
        } catch {
            appModel.reportUserError(title: String(localized: "Export Failed", bundle: bundle), message: error.localizedDescription)
        }
    }

    @MainActor
    func handleFeedSave(_ result: FeedEditorResult) async throws {
        switch result {
        case .add(let title, let url):
            try await appModel.addFeed(title: title, feedURL: url, siteURL: nil)
        case .edit(let feed, let title, let url):
            try await appModel.updateFeed(feed, title: title, feedURL: url, siteURL: feed.siteURL)
        }
        await reloadAfterFeedChange()
    }

    @MainActor
    func deleteFeed(_ feed: Feed) async {
        do {
            try await appModel.deleteFeed(feed)
            await reloadAfterFeedChange(keepSelection: false)
        } catch {
            appModel.reportUserError(title: String(localized: "Delete Failed", bundle: bundle), message: error.localizedDescription)
        }
    }

    @MainActor
    func reloadAfterFeedChange(keepSelection: Bool = true) async {
        await appModel.feedStore.loadAll()
        await appModel.refreshCounts()

        if keepSelection {
            switch selectedFeedSelection {
            case .all, .starred:
                await loadEntries(for: selectedFeedSelection, unreadOnly: showUnreadOnly, selectFirst: selectedEntryId == nil)
            case .feed(let selectedFeedId):
                if appModel.feedStore.feeds.contains(where: { $0.id == selectedFeedId }) {
                    await loadEntries(for: selectedFeedSelection, unreadOnly: showUnreadOnly, selectFirst: selectedEntryId == nil)
                } else {
                    selectedFeedSelection = .all
                    await loadEntries(for: .all, unreadOnly: showUnreadOnly, selectFirst: true)
                }
            }
        } else {
            selectedFeedSelection = .all
            await loadEntries(for: .all, unreadOnly: showUnreadOnly, selectFirst: true)
        }
    }

    @MainActor
    func selectOPMLFile() -> URL? {
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
    func selectOPMLExportURL() -> URL? {
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

    var opmlContentType: UTType {
        UTType(filenameExtension: "opml") ?? .xml
    }
}
