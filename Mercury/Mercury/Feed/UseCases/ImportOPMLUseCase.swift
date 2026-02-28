//
//  ImportOPMLUseCase.swift
//  Mercury
//

import Foundation
import GRDB

struct ImportOPMLUseCase {
    let database: DatabaseManager
    let syncService: SyncService
    let feedSyncUseCase: FeedSyncUseCase

    func run(
        from url: URL,
        replaceExisting: Bool,
        forceSiteNameAsFeedTitle: Bool,
        report: TaskProgressReporter,
        maxConcurrentFeeds: Int = 6,
        onMutation: @escaping () async -> Void,
        onSyncError: (@Sendable (_ feedId: Int64, _ error: Error) async -> Void)? = nil,
        onSkippedInsecureFeed: (@Sendable (_ feedURL: String) async -> Void)? = nil
    ) async throws {
        let importer = OPMLImporter()
        let rawFeeds = try SecurityScopedBookmarkStore.access(url) {
            try importer.parse(url: url)
        }

        let (feeds, skippedInsecure) = splitSecureFeeds(rawFeeds)
        if skippedInsecure > 0 {
            await report(0.03, "Skipped \(skippedInsecure) insecure feeds (HTTP)")
            if let onSkippedInsecureFeed {
                for item in rawFeeds {
                    if isSecureFeedURL(item.feedURL) == false {
                        await onSkippedInsecureFeed(item.feedURL)
                    }
                }
            }
        }

        if feeds.isEmpty {
            await report(1, "No feeds found in OPML")
            return
        }

        await report(0.05, "Parsed \(feeds.count) feeds")

        if replaceExisting {
            _ = try await database.write { db in
                try Feed.deleteAll(db)
            }
            await onMutation()
        }

        let batchSize = 24
        var processed = 0
        var insertedFeedIds: [Int64] = []

        for start in stride(from: 0, to: feeds.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, feeds.count)
            let batch = Array(feeds[start..<end])
            let batchWithTitles = await FeedTitleResolver.resolveAutomaticTitles(
                for: batch,
                forceSiteNameAsFeedTitle: forceSiteNameAsFeedTitle,
                fetchFeedTitle: { url in
                    try await syncService.fetchFeedTitle(from: url)
                }
            )
            let inserted = try await upsertOPMLBatch(batchWithTitles)
            insertedFeedIds.append(contentsOf: inserted)
            processed += batch.count

            let progress = 0.1 + 0.5 * (Double(processed) / Double(feeds.count))
            await report(progress, "Imported \(processed)/\(feeds.count) feeds")
            await onMutation()
        }

        let syncTargetFeedIds: [Int64]
        if replaceExisting {
            syncTargetFeedIds = try await feedSyncUseCase.loadAllFeedIDs()
        } else {
            syncTargetFeedIds = insertedFeedIds
        }

        if syncTargetFeedIds.isEmpty {
            await report(1, "Import completed")
            return
        }

        try await feedSyncUseCase.sync(
            feedIds: syncTargetFeedIds,
            report: report,
            maxConcurrentFeeds: maxConcurrentFeeds,
            progressStart: 0.6,
            progressSpan: 0.4,
            refreshStride: 1,
            continueOnError: true,
            onError: onSyncError,
            onRefresh: onMutation
        )

        await report(1, "Import completed")
    }

    private func upsertOPMLBatch(_ feeds: [OPMLFeed]) async throws -> [Int64] {
        try await database.write { db in
            var insertedFeedIds: [Int64] = []
            for item in feeds {
                if var existing = try Feed.filter(Column("feedURL") == item.feedURL).fetchOne(db) {
                    if let title = item.title { existing.title = title }
                    if let siteURL = item.siteURL { existing.siteURL = siteURL }
                    try existing.update(db)
                } else {
                    var feed = Feed(
                        id: nil,
                        title: item.title,
                        feedURL: item.feedURL,
                        siteURL: item.siteURL,
                        unreadCount: 0,
                        lastFetchedAt: nil,
                        createdAt: Date()
                    )
                    try feed.insert(db)
                    if let feedId = feed.id {
                        insertedFeedIds.append(feedId)
                    }
                }
            }
            return insertedFeedIds
        }
    }

    private func splitSecureFeeds(_ feeds: [OPMLFeed]) -> (secure: [OPMLFeed], insecureCount: Int) {
        var secure: [OPMLFeed] = []
        secure.reserveCapacity(feeds.count)
        var insecureCount = 0
        for item in feeds {
            if isSecureFeedURL(item.feedURL) {
                secure.append(item)
            } else {
                insecureCount += 1
            }
        }
        return (secure, insecureCount)
    }

    private func isSecureFeedURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https"
    }
}
