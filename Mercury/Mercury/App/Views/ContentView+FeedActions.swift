import AppKit
import UniformTypeIdentifiers

extension ContentView {
    func beginAddFeed() {
        editorState = FeedEditorState(mode: .add)
    }

    func beginEditFeed(_ feed: Feed) {
        editorState = FeedEditorState(mode: .edit(feed))
    }

    func requestDeleteFeed(_ feed: Feed) {
        pendingDeleteFeed = feed
    }

    func syncFeedsNow() {
        Task {
            await appModel.syncAllFeeds()
        }
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
