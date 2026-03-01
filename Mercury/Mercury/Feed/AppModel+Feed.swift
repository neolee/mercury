//
//  AppModel+Feed.swift
//  Mercury
//

import Foundation
import GRDB
extension AppModel {
    func markEntriesReadState(query: EntryStore.EntryListQuery, isRead: Bool) async {
        do {
            let affectedFeedIds = try await entryStore.markRead(query: query, isRead: isRead)
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

    func markEntryRead(entryId: Int64, feedId: Int64, isRead: Bool) async {
        guard isRead == false else { return }

        do {
            try await entryStore.markRead(entryId: entryId, isRead: true)
            _ = try await feedStore.updateUnreadCount(for: feedId)
            totalUnreadCount = feedStore.totalUnreadCount
        } catch {
            return
        }
    }

    /// Sets the read state of a single entry to the given target value regardless of its current state.
    func setEntryReadState(entryId: Int64, feedId: Int64, isRead: Bool) async {
        do {
            try await entryStore.markRead(entryId: entryId, isRead: isRead)
            _ = try await feedStore.updateUnreadCount(for: feedId)
            totalUnreadCount = feedStore.totalUnreadCount
        } catch {
            return
        }
    }

    func setEntryStarredState(entryId: Int64, isStarred: Bool) async {
        do {
            try await entryStore.markStarred(entryId: entryId, isStarred: isStarred)
        } catch {
            reportDebugIssue(
                title: "Update Starred State Failed",
                detail: [
                    "entryId=\(entryId)",
                    "targetIsStarred=\(isStarred)",
                    "error=\(error.localizedDescription)"
                ].joined(separator: "\n"),
                category: .task
            )
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
