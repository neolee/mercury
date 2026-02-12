//
//  AppModel+FeedCRUD.swift
//  Mercury
//

import Foundation
import GRDB
extension AppModel {
    func markLoadedEntriesReadState(isRead: Bool) async {
        let loadedEntries = entryStore.entries
        let entryIds = loadedEntries.compactMap(\.id)
        guard entryIds.isEmpty == false else { return }

        let affectedFeedIds = loadedEntries.map(\.feedId)

        do {
            try await entryStore.markRead(entryIds: entryIds, isRead: isRead)
            try await feedStore.updateUnreadCounts(for: affectedFeedIds)
            totalUnreadCount = feedStore.totalUnreadCount
        } catch {
            reportUserError(title: "Update Read State Failed", message: error.localizedDescription)
        }
    }

    func markEntryRead(_ entry: Entry) async {
        guard let entryId = entry.id else { return }
        guard entry.isRead == false else { return }

        do {
            try await entryStore.markRead(entryId: entryId, isRead: true)
            _ = try await feedStore.updateUnreadCount(for: entry.feedId)
            totalUnreadCount = feedStore.totalUnreadCount
        } catch {
            return
        }
    }

    func refreshUnreadTotals() {
        totalUnreadCount = feedStore.totalUnreadCount
    }

    func refreshCounts() async {
        do {
            feedCount = try await database.read { db in
                try Feed.fetchCount(db)
            }
            entryCount = try await database.read { db in
                try Entry.fetchCount(db)
            }
        } catch {
            feedCount = feedStore.feeds.count
        }
        totalUnreadCount = feedStore.totalUnreadCount
    }

    func addFeed(title: String?, feedURL: String, siteURL: String?) async throws {
        let resolvedFeedId = try await feedCRUDUseCase.addFeed(
            title: title,
            feedURL: feedURL,
            siteURL: siteURL
        )
        await feedStore.loadAll()
        await refreshCounts()

        var feedIdToSync = resolvedFeedId
        if feedIdToSync == nil {
            feedIdToSync = try? await database.read { db in
                try Feed
                    .filter(Column("feedURL") == feedURL)
                    .fetchOne(db)?
                    .id
            }
        }

        if let feedIdToSync {
            await enqueueFeedSync(
                feedIds: [feedIdToSync],
                title: "Sync New Feed",
                priority: .userInitiated
            )
        } else {
            reportDebugIssue(
                title: "Add Feed Sync Skipped",
                detail: "Missing feed ID after addFeed; cannot enqueue sync. feedURL=\(feedURL)",
                category: .task
            )
        }
    }

    func updateFeed(_ feed: Feed, title: String?, feedURL: String, siteURL: String?) async throws {
        let resolvedFeedId = try await feedCRUDUseCase.updateFeed(
            feed,
            title: title,
            feedURL: feedURL,
            siteURL: siteURL
        )
        await feedStore.loadAll()
        await refreshCounts()

        if let feedId = resolvedFeedId {
            await enqueueFeedSync(
                feedIds: [feedId],
                title: "Sync Feed",
                priority: .utility
            )
        }
    }

    func deleteFeed(_ feed: Feed) async throws {
        try await feedCRUDUseCase.deleteFeed(feed)
        await feedStore.loadAll()
        await refreshCounts()
    }

    func fetchFeedTitle(for urlString: String) async throws -> String? {
        try await feedCRUDUseCase.fetchFeedTitle(for: urlString)
    }
}
