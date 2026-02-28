//
//  BootstrapUseCase.swift
//  Mercury
//

import Foundation
import GRDB

struct BootstrapUseCase {
    let database: DatabaseManager
    let feedSyncUseCase: FeedSyncUseCase

    func run(
        report: TaskProgressReporter,
        maxConcurrentFeeds: Int = 6,
        onMutation: @escaping () async -> Void,
        onSyncError: (@Sendable (_ feedId: Int64, _ error: Error) async -> Void)? = nil,
        onSkippedInsecureFeed: (@Sendable (_ feedURL: String) async -> Void)? = nil
    ) async throws {
        await report(0.05, "Checking local feeds")
        let currentFeedCount = try await database.read { db in
            try Feed.fetchCount(db)
        }

        if currentFeedCount == 0 {
            await report(0.12, "Importing starter feeds")
            let imported = try await importStarterFeeds(report: report, onSkippedInsecureFeed: onSkippedInsecureFeed)
            await onMutation()

            let feedIds: [Int64]
            if imported.isEmpty {
                feedIds = try await feedSyncUseCase.loadAllFeedIDs()
            } else {
                feedIds = imported
            }

            if feedIds.isEmpty {
                await report(1, "Bootstrap completed")
                return
            }

            try await feedSyncUseCase.sync(
                feedIds: feedIds,
                report: report,
                maxConcurrentFeeds: maxConcurrentFeeds,
                progressStart: 0.35,
                progressSpan: 0.65,
                refreshStride: 3,
                continueOnError: true,
                onError: onSyncError,
                onRefresh: onMutation
            )

            await report(1, "Bootstrap completed")
            return
        }

        let feedIds = try await feedSyncUseCase.loadAllFeedIDs()
        try await feedSyncUseCase.sync(
            feedIds: feedIds,
            report: report,
            maxConcurrentFeeds: maxConcurrentFeeds,
            progressStart: 0.15,
            progressSpan: 0.8,
            refreshStride: 5,
            continueOnError: true,
            onError: onSyncError,
            onRefresh: onMutation
        )
    }

    private func importStarterFeeds(
        report: TaskProgressReporter,
        onSkippedInsecureFeed: (@Sendable (_ feedURL: String) async -> Void)?
    ) async throws -> [Int64] {
        guard let url = starterOPMLURL() else {
            await report(0.3, "Starter OPML not found")
            return []
        }

        let importer = OPMLImporter()
        let rawFeeds = try importer.parse(url: url)
        let (feeds, skippedInsecure) = splitSecureFeeds(rawFeeds)
        if skippedInsecure > 0 {
            await report(0.18, "Skipped \(skippedInsecure) insecure feeds (HTTP)")
            if let onSkippedInsecureFeed {
                for item in rawFeeds {
                    if isSecureFeedURL(item.feedURL) == false {
                        await onSkippedInsecureFeed(item.feedURL)
                    }
                }
            }
        }
        if feeds.isEmpty {
            await report(0.3, "No starter feeds")
            return []
        }

        await report(0.2, "Parsed \(feeds.count) starter feeds")

        return try await database.write { db in
            var insertedFeedIds: [Int64] = []
            insertedFeedIds.reserveCapacity(feeds.count)

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
                    if let id = feed.id {
                        insertedFeedIds.append(id)
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

    private func starterOPMLURL() -> URL? {
        let candidates = starterOPMLCandidateURLs()
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func starterOPMLCandidateURLs() -> [URL] {
        var candidates: [URL] = []

        if let bundled = Bundle.main.url(forResource: "hn-popular10+1", withExtension: "opml") {
            candidates.append(bundled)
        }

        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("hn-popular10+1.opml") {
            candidates.append(resourceURL)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Mercury/Resources/hn-popular10+1.opml"))
        candidates.append(cwd.appendingPathComponent("Resources/hn-popular10+1.opml"))

        return candidates
    }
}
