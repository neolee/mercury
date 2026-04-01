//
//  FeedCRUDUseCase.swift
//  Mercury
//

import Foundation
import FeedKit
import GRDB

struct FeedCRUDUseCase {
    let database: DatabaseManager
    let feedLoadUseCase: FeedLoadUseCase
    let feedEntryMapper: FeedEntryMapper
    let validator: FeedInputValidator

    func addFeed(
        title: String?,
        feedURL: String,
        siteURL: String?,
        verifiedFeed: FeedLoadUseCase.VerifiedFeed? = nil
    ) async throws -> Feed {
        let normalizedURL = try validator.validateFeedURL(verifiedFeed?.feedURL ?? feedURL)
        if try await validator.feedExists(withURL: normalizedURL) {
            throw FeedEditError.duplicateFeed
        }

        let resolvedVerifiedFeed: FeedLoadUseCase.VerifiedFeed
        if let verifiedFeed {
            if verifiedFeed.feedURL != normalizedURL {
                throw FeedEditError.invalidURL
            }
            resolvedVerifiedFeed = verifiedFeed
        } else {
            do {
                resolvedVerifiedFeed = try await feedLoadUseCase.loadAndVerifyFeed(from: normalizedURL)
            } catch {
                throw mapEditableFeedError(error)
            }
        }

        let resolvedTitle = validator.normalizedTitle(title) ?? validator.normalizedTitle(resolvedVerifiedFeed.title)
        return try await persistFeed(
            title: resolvedTitle,
            feedURL: resolvedVerifiedFeed.feedURL,
            siteURL: siteURL,
            parsedFeed: resolvedVerifiedFeed.parsedFeed
        )
    }

    func updateFeed(
        _ feed: Feed,
        title: String?,
        feedURL: String,
        siteURL: String?,
        verifiedFeed: FeedLoadUseCase.VerifiedFeed? = nil
    ) async throws -> Feed {
        let normalizedURL = try validator.validateFeedURL(feedURL)
        if normalizedURL != feed.feedURL {
            if try await validator.feedExists(withURL: normalizedURL, excludingFeedId: feed.id) {
                throw FeedEditError.duplicateFeed
            }

            if let verifiedFeed {
                if verifiedFeed.feedURL != normalizedURL {
                    throw FeedEditError.invalidURL
                }
            } else {
                do {
                    _ = try await feedLoadUseCase.loadAndVerifyFeed(from: normalizedURL)
                } catch {
                    throw mapEditableFeedError(error)
                }
            }
        }

        return try await persistFeed(
            title: title,
            feedURL: normalizedURL,
            siteURL: siteURL,
            existingFeed: feed
        )
    }

    func deleteFeed(_ feed: Feed) async throws {
        try await database.write { db in
            _ = try feed.delete(db)
        }
    }

    func loadAndVerifyFeed(for urlString: String) async throws -> FeedLoadUseCase.VerifiedFeed {
        do {
            return try await feedLoadUseCase.loadAndVerifyFeed(from: urlString)
        } catch {
            throw mapEditableFeedError(error)
        }
    }

    func fetchFeedTitle(for urlString: String) async throws -> String? {
        try await loadAndVerifyFeed(for: urlString).title
    }

    func persistFeed(
        title: String?,
        feedURL: String,
        siteURL: String?,
        existingFeed: Feed? = nil,
        parsedFeed: FeedKit.Feed? = nil
    ) async throws -> Feed {
        let normalizedURL = try validator.validateFeedURL(feedURL)
        let normalizedSiteURL = validator.normalizedURLString(siteURL)
        let normalizedTitle = validator.normalizedTitle(title)

        if try await validator.feedExists(withURL: normalizedURL, excludingFeedId: existingFeed?.id) {
            throw FeedEditError.duplicateFeed
        }

        do {
            return try await database.write { db in
                let fetchedAt = parsedFeed == nil ? existingFeed?.lastFetchedAt : Date()
                var persistedFeed = existingFeed ?? Feed(
                    id: nil,
                    title: normalizedTitle,
                    feedURL: normalizedURL,
                    siteURL: normalizedSiteURL,
                    lastFetchedAt: fetchedAt,
                    createdAt: Date()
                )

                persistedFeed.title = normalizedTitle
                persistedFeed.feedURL = normalizedURL
                persistedFeed.siteURL = normalizedSiteURL
                persistedFeed.lastFetchedAt = fetchedAt

                try persistedFeed.save(db)

                if let parsedFeed, let feedId = persistedFeed.id {
                    let entries = feedEntryMapper.makeEntries(
                        from: parsedFeed,
                        feedId: feedId,
                        baseURLString: normalizedSiteURL ?? normalizedURL
                    )
                    for var entry in entries {
                        try entry.insert(db, onConflict: .ignore)
                    }
                }

                return persistedFeed
            }
        } catch {
            if FeedInputValidator.isDuplicateFeedURLError(error) {
                throw FeedEditError.duplicateFeed
            }
            throw error
        }
    }

    private func mapEditableFeedError(_ error: Error) -> Error {
        if let feedEditError = error as? FeedEditError {
            return feedEditError
        }

        if FailurePolicy.classifyFeedSyncError(error) == .unsupportedFormat {
            return FeedEditError.unsupportedFeed
        }

        let underlyingError: NSError
        if let diagnosticError = error as? FeedSyncDiagnosticError {
            underlyingError = diagnosticError.underlying as NSError
        } else {
            underlyingError = error as NSError
        }

        return FeedEditError.feedLoadFailed(underlyingError.localizedDescription)
    }
}
