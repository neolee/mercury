//
//  AppModel+Feed.swift
//  Mercury
//

import Foundation
import GRDB
extension AppModel {
    func markEntriesReadState(query: EntryStore.EntryListQuery, isRead: Bool) async {
        do {
            _ = try await entryStore.markRead(query: query, isRead: isRead)
        } catch {
            reportUserError(title: "Update Read State Failed", message: error.localizedDescription)
        }
    }

    func markEntryRead(_ entry: Entry) async {
        guard let entryId = entry.id else { return }
        guard entry.isRead == false else { return }

        do {
            try await entryStore.markRead(entryId: entryId, isRead: true)
        } catch {
            return
        }
    }

    func markEntryRead(entryId: Int64, feedId: Int64, isRead: Bool) async {
        guard isRead == false else { return }

        do {
            try await entryStore.markRead(entryId: entryId, isRead: true)
        } catch {
            return
        }
    }

    /// Sets the read state of a single entry to the given target value regardless of its current state.
    func setEntryReadState(entryId: Int64, feedId: Int64, isRead: Bool) async {
        do {
            try await entryStore.markRead(entryId: entryId, isRead: isRead)
        } catch {
            return
        }
    }

    func setEntryStarredState(entryId: Int64, isStarred: Bool) async -> Bool {
        do {
            try await entryStore.markStarred(entryId: entryId, isStarred: isStarred)
            return true
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
            return false
        }
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
    }

    func addFeed(title: String?, feedURL: String, siteURL: String?) async throws {
        _ = try await feedCRUDUseCase.addFeed(
            title: title,
            feedURL: feedURL,
            siteURL: siteURL
        )
        await refreshAfterBackgroundMutation()
    }

    func addFeed(
        title: String?,
        feedURL: String,
        siteURL: String?,
        verifiedFeed: FeedLoadUseCase.VerifiedFeed?
    ) async throws {
        _ = try await feedCRUDUseCase.addFeed(
            title: title,
            feedURL: feedURL,
            siteURL: siteURL,
            verifiedFeed: verifiedFeed
        )
        await refreshAfterBackgroundMutation()
    }

    func updateFeed(_ feed: Feed, title: String?, feedURL: String, siteURL: String?) async throws {
        let updatedFeed = try await feedCRUDUseCase.updateFeed(
            feed,
            title: title,
            feedURL: feedURL,
            siteURL: siteURL
        )
        await refreshAfterBackgroundMutation()

        if updatedFeed.feedURL != feed.feedURL, let feedId = updatedFeed.id {
            await enqueueFeedSync(
                feedIds: [feedId],
                title: "Sync Feed",
                priority: .utility
            )
        }
    }

    func updateFeed(
        _ feed: Feed,
        title: String?,
        feedURL: String,
        siteURL: String?,
        verifiedFeed: FeedLoadUseCase.VerifiedFeed?
    ) async throws {
        let updatedFeed = try await feedCRUDUseCase.updateFeed(
            feed,
            title: title,
            feedURL: feedURL,
            siteURL: siteURL,
            verifiedFeed: verifiedFeed
        )
        await refreshAfterBackgroundMutation()

        if updatedFeed.feedURL != feed.feedURL, let feedId = updatedFeed.id {
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

    func loadAndVerifyFeed(for urlString: String) async throws -> FeedLoadUseCase.VerifiedFeed {
        try await feedCRUDUseCase.loadAndVerifyFeed(for: urlString)
    }
}
