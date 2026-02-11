//
//  UseCases.swift
//  Mercury
//

import Foundation
import GRDB

struct FeedSyncUseCase {
    let database: DatabaseManager
    let syncService: SyncService

    func loadAllFeedIDs() async throws -> [Int64] {
        try await database.read { db in
            try Feed.fetchAll(db).compactMap(\.id)
        }
    }

    func sync(
        feedIds: [Int64],
        report: TaskProgressReporter,
        progressStart: Double,
        progressSpan: Double,
        refreshStride: Int,
        continueOnError: Bool = false,
        onRefresh: @escaping () async -> Void
    ) async throws {
        guard feedIds.isEmpty == false else {
            await report(progressStart + progressSpan, "No feeds to sync")
            return
        }

        let total = feedIds.count
        let stride = max(refreshStride, 1)
        for (index, feedId) in feedIds.enumerated() {
            try Task.checkCancellation()
            do {
                try await syncService.syncFeed(withId: feedId)
            } catch {
                if continueOnError == false {
                    throw error
                }
            }

            let completed = index + 1
            let progress = progressStart + (progressSpan * Double(completed) / Double(total))
            await report(progress, "Synced \(completed)/\(total) feeds")

            if completed % stride == 0 || completed == total {
                await onRefresh()
            }
        }
    }
}

struct ImportOPMLUseCase {
    let database: DatabaseManager
    let syncService: SyncService
    let feedSyncUseCase: FeedSyncUseCase

    func run(
        from url: URL,
        replaceExisting: Bool,
        forceSiteNameAsFeedTitle: Bool,
        report: TaskProgressReporter,
        onMutation: @escaping () async -> Void
    ) async throws {
        let importer = OPMLImporter()
        let feeds = try SecurityScopedBookmarkStore.access(url) {
            try importer.parse(url: url)
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
            progressStart: 0.6,
            progressSpan: 0.4,
            refreshStride: 1,
            continueOnError: true,
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
}

struct ExportOPMLUseCase {
    let database: DatabaseManager

    func run(to url: URL, report: TaskProgressReporter) async throws {
        await report(0.1, "Loading feeds")
        let feeds = try await database.read { db in
            try Feed
                .order(Column("title").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }

        await report(0.55, "Generating OPML")
        let exporter = OPMLExporter()
        let opml = exporter.export(feeds: feeds, title: "Mercury Subscriptions")

        await report(0.85, "Writing file")
        try SecurityScopedBookmarkStore.access(url) {
            try opml.write(to: url, atomically: true, encoding: .utf8)
        }
        await report(1, "Export completed")
    }
}

struct BootstrapUseCase {
    let database: DatabaseManager
    let syncService: SyncService
    let feedSyncUseCase: FeedSyncUseCase

    func run(
        report: TaskProgressReporter,
        onMutation: @escaping () async -> Void
    ) async throws {
        await report(0.05, "Checking local feeds")
        let currentFeedCount = try await database.read { db in
            try Feed.fetchCount(db)
        }

        if currentFeedCount == 0 {
            await report(0.15, "Importing starter feeds")
            try await syncService.bootstrapIfNeeded(limit: 10)
            await onMutation()
            return
        }

        let feedIds = try await feedSyncUseCase.loadAllFeedIDs()
        try await feedSyncUseCase.sync(
            feedIds: feedIds,
            report: report,
            progressStart: 0.15,
            progressSpan: 0.8,
            refreshStride: 5,
            continueOnError: false,
            onRefresh: onMutation
        )
    }
}
