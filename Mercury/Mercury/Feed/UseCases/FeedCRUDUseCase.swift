//
//  FeedCRUDUseCase.swift
//  Mercury
//

import Foundation
import GRDB

struct FeedCRUDUseCase {
    let database: DatabaseManager
    let syncService: SyncService
    let validator: FeedInputValidator

    func addFeed(title: String?, feedURL: String, siteURL: String?) async throws -> Int64? {
        let normalizedURL = try validator.validateFeedURL(feedURL)
        if try await validator.feedExists(withURL: normalizedURL) {
            throw FeedEditError.duplicateFeed
        }

        let normalizedSiteURL = validator.normalizedURLString(siteURL)
        let resolvedTitle = await FeedTitleResolver.resolveAutomaticFeedTitle(
            explicitTitle: title,
            feedURL: normalizedURL,
            siteURL: normalizedSiteURL,
            fetchFeedTitle: { [syncService] url in
                try await syncService.fetchFeedTitle(from: url)
            }
        )

        do {
            return try await database.write { db in
                var feed = Feed(
                    id: nil,
                    title: validator.normalizedTitle(resolvedTitle),
                    feedURL: normalizedURL,
                    siteURL: normalizedSiteURL,
                    unreadCount: 0,
                    lastFetchedAt: nil,
                    createdAt: Date()
                )
                try feed.insert(db)
                return feed.id
            }
        } catch {
            if FeedInputValidator.isDuplicateFeedURLError(error) {
                throw FeedEditError.duplicateFeed
            }
            throw error
        }
    }

    func updateFeed(_ feed: Feed, title: String?, feedURL: String, siteURL: String?) async throws -> Int64? {
        var updated = feed
        updated.title = validator.normalizedTitle(title)
        updated.feedURL = try validator.validateFeedURL(feedURL)
        updated.siteURL = validator.normalizedURLString(siteURL)

        if try await validator.feedExists(withURL: updated.feedURL, excludingFeedId: updated.id) {
            throw FeedEditError.duplicateFeed
        }

        do {
            try await database.write { db in
                var mutable = updated
                try mutable.save(db)
            }
            return updated.id
        } catch {
            if FeedInputValidator.isDuplicateFeedURLError(error) {
                throw FeedEditError.duplicateFeed
            }
            throw error
        }
    }

    func deleteFeed(_ feed: Feed) async throws {
        try await database.write { db in
            _ = try feed.delete(db)
        }
    }

    func fetchFeedTitle(for urlString: String) async throws -> String? {
        let normalizedURL = try validator.validateFeedURL(urlString)
        return try await syncService.fetchFeedTitle(from: normalizedURL)
    }
}
