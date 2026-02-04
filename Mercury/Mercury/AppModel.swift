//
//  AppModel.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Combine
import Foundation
import GRDB

@MainActor
final class AppModel: ObservableObject {
    let database: DatabaseManager
    let feedStore: FeedStore
    let entryStore: EntryStore
    let contentStore: ContentStore
    private let syncService: SyncService

    @Published private(set) var isReady: Bool = false
    @Published private(set) var feedCount: Int = 0
    @Published private(set) var entryCount: Int = 0
    @Published private(set) var totalUnreadCount: Int = 0
    @Published private(set) var bootstrapState: BootstrapState = .idle

    init() {
        do {
            database = try DatabaseManager()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }

        feedStore = FeedStore(db: database)
        entryStore = EntryStore(db: database)
        contentStore = ContentStore(db: database)
        syncService = SyncService(db: database)
        isReady = true
    }

    func bootstrapIfNeeded() async {
        guard bootstrapState == .idle else { return }
        bootstrapState = .importing

        do {
            try await syncService.bootstrapIfNeeded(limit: 10)
            await feedStore.loadAll()
            feedCount = feedStore.feeds.count
            entryCount = try await database.read { db in
                try Entry.fetchCount(db)
            }
            totalUnreadCount = feedStore.totalUnreadCount
            bootstrapState = .ready
        } catch {
            bootstrapState = .failed(error.localizedDescription)
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
        let normalizedURL = try validateFeedURL(feedURL)
        let resolvedTitle: String?
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            resolvedTitle = title
        } else {
            resolvedTitle = try await fetchFeedTitle(for: normalizedURL)
        }

        let feed = Feed(
            id: nil,
            title: normalizedTitle(resolvedTitle),
            feedURL: normalizedURL,
            siteURL: normalizedURLString(siteURL),
            unreadCount: 0,
            lastFetchedAt: nil,
            createdAt: Date()
        )

        try await feedStore.upsert(feed)
        try await syncService.syncAllFeeds()
        await feedStore.loadAll()
        await refreshCounts()
    }

    func updateFeed(_ feed: Feed, title: String?, feedURL: String, siteURL: String?) async throws {
        var updated = feed
        updated.title = normalizedTitle(title)
        updated.feedURL = try validateFeedURL(feedURL)
        updated.siteURL = normalizedURLString(siteURL)

        try await feedStore.upsert(updated)
        try await syncService.syncAllFeeds()
        await feedStore.loadAll()
        await refreshCounts()
    }

    func deleteFeed(_ feed: Feed) async throws {
        try await feedStore.delete(feed)
        await feedStore.loadAll()
        await refreshCounts()
    }

    func importOPML(from url: URL, replaceExisting: Bool) async throws {
        let importer = OPMLImporter()
        let feeds = try SecurityScopedBookmarkStore.access(url) {
            try importer.parse(url: url)
        }

        try await database.write { db in
            if replaceExisting {
                try Feed.deleteAll(db)
            }

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
                }
            }
        }

        try await syncService.syncAllFeeds()
        await feedStore.loadAll()
        await refreshCounts()
    }

    func exportOPML(to url: URL) async throws {
        let feeds = try await database.read { db in
            try Feed.order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }

        let exporter = OPMLExporter()
        let opml = exporter.export(feeds: feeds, title: "Mercury Subscriptions")

        try SecurityScopedBookmarkStore.access(url) {
            try opml.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func fetchFeedTitle(for urlString: String) async throws -> String? {
        let normalizedURL = try validateFeedURL(urlString)
        return try await syncService.fetchFeedTitle(from: normalizedURL)
    }

    private func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedURLString(_ urlString: String?) -> String? {
        guard let urlString else { return nil }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validateFeedURL(_ urlString: String) throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw FeedEditError.invalidURL }
        guard let url = URL(string: trimmed), url.scheme != nil else { throw FeedEditError.invalidURL }
        return trimmed
    }
}

enum FeedEditError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Please enter a valid feed URL."
        }
    }
}

enum BootstrapState: Equatable {
    case idle
    case importing
    case ready
    case failed(String)
}