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
        let activeFeedId = (searchScope == .allFeeds) ? nil : selectedFeedId
        let query = EntryStore.EntryListQuery(
            feedId: activeFeedId,
            unreadOnly: showUnreadOnly,
            keepEntryId: nil,
            searchText: searchText
        )
        await appModel.markEntriesReadState(query: query, isRead: isRead)
        await loadEntries(for: selectedFeedId, unreadOnly: showUnreadOnly, keepEntryId: nil, selectFirst: true)
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

        if keepSelection, let selectedFeedId,
           appModel.feedStore.feeds.contains(where: { $0.id == selectedFeedId }) {
            await loadEntries(for: selectedFeedId, unreadOnly: showUnreadOnly, selectFirst: selectedEntryId == nil)
        } else {
            selectedFeedSelection = .all
            await loadEntries(for: selectedFeedId, unreadOnly: showUnreadOnly, selectFirst: true)
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
