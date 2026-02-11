//
//  AppModel+FeedCRUD.swift
//  Mercury
//

import Foundation
import GRDB

extension AppModel {
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
        let normalizedURL = try validateFeedURL(feedURL)
        if try await feedExists(withURL: normalizedURL) {
            throw FeedEditError.duplicateFeed
        }
        let normalizedSiteURL = normalizedURLString(siteURL)
        let resolvedTitle = await FeedTitleResolver.resolveAutomaticFeedTitle(
            explicitTitle: title,
            feedURL: normalizedURL,
            siteURL: normalizedSiteURL,
            fetchFeedTitle: { [syncService] url in
                try await syncService.fetchFeedTitle(from: url)
            }
        )

        let feed = Feed(
            id: nil,
            title: normalizedTitle(resolvedTitle),
            feedURL: normalizedURL,
            siteURL: normalizedSiteURL,
            unreadCount: 0,
            lastFetchedAt: nil,
            createdAt: Date()
        )

        do {
            try await feedStore.upsert(feed)
        } catch {
            if isDuplicateFeedURLError(error) {
                throw FeedEditError.duplicateFeed
            }
            throw error
        }
        let resolvedFeedId = try await database.read { db in
            try Feed.filter(Column("feedURL") == normalizedURL).fetchOne(db)?.id
        }
        await feedStore.loadAll()
        await refreshCounts()

        if let feedId = resolvedFeedId {
            await enqueueFeedSync(
                feedIds: [feedId],
                title: "Sync New Feed",
                priority: .userInitiated
            )
        }
    }

    func updateFeed(_ feed: Feed, title: String?, feedURL: String, siteURL: String?) async throws {
        var updated = feed
        updated.title = normalizedTitle(title)
        updated.feedURL = try validateFeedURL(feedURL)
        updated.siteURL = normalizedURLString(siteURL)
        if try await feedExists(withURL: updated.feedURL, excludingFeedId: feed.id) {
            throw FeedEditError.duplicateFeed
        }

        do {
            try await feedStore.upsert(updated)
        } catch {
            if isDuplicateFeedURLError(error) {
                throw FeedEditError.duplicateFeed
            }
            throw error
        }
        await feedStore.loadAll()
        await refreshCounts()

        if let feedId = updated.id {
            await enqueueFeedSync(
                feedIds: [feedId],
                title: "Sync Feed",
                priority: .utility
            )
        }
    }

    func deleteFeed(_ feed: Feed) async throws {
        try await feedStore.delete(feed)
        await feedStore.loadAll()
        await refreshCounts()
    }

    func fetchFeedTitle(for urlString: String) async throws -> String? {
        let normalizedURL = try validateFeedURL(urlString)
        return try await syncService.fetchFeedTitle(from: normalizedURL)
    }
}
