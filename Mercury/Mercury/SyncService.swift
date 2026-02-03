//
//  SyncService.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation
import FeedKit
import GRDB
import XMLKit

final class SyncService {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func bootstrapIfNeeded(limit: Int) async throws {
        let feedCount = try await db.read { db in
            try Feed.fetchCount(db)
        }

        if feedCount == 0 {
            try await importOPML(limit: limit)
        }

        try await syncAllFeeds()
    }

    private func importOPML(limit: Int) async throws {
        let candidateURLs = opmlCandidateURLs()
        guard let url = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SyncError.missingOPML(candidateURLs.map { $0.path })
        }

        let importer = OPMLImporter()
        let feeds = try importer.parse(url: url, limit: limit)

        try await db.write { db in
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
    }

    func syncAllFeeds() async throws {
        let feeds = try await db.read { db in
            try Feed.fetchAll(db)
        }

        for feed in feeds {
            do {
                try await sync(feed)
            } catch {
                continue
            }
        }

        try await recalculateUnreadCounts()
    }

    private func sync(_ feed: Feed) async throws {
        guard let feedId = feed.id else { return }
        guard let url = URL(string: feed.feedURL) else { return }
        guard let secureURL = forceSecureURL(url) else { return }

        let parsedFeed: FeedKit.Feed
        do {
            parsedFeed = try await FeedKit.Feed(url: secureURL)
        } catch {
            try await deleteFeed(feed)
            return
        }
        let entries = mapEntries(feed: parsedFeed, feedId: feedId)

        try await db.write { db in
            for var entry in entries {
                try entry.insert(db, onConflict: .ignore)
            }

            var updated = feed
            if secureURL.absoluteString != feed.feedURL {
                updated.feedURL = secureURL.absoluteString
            }
            updated.lastFetchedAt = Date()
            try updated.update(db)
        }
    }

    private func mapEntries(feed: FeedKit.Feed, feedId: Int64) -> [Entry] {
        switch feed {
        case .rss(let rss):
            return mapRSSItems(rss.channel?.items, feedId: feedId)
        case .atom(let atom):
            return mapAtomEntries(atom.entries, feedId: feedId)
        case .json(let json):
            return mapJSONItems(json.items, feedId: feedId)
        }
    }

    private func mapRSSItems(_ items: [RSSFeedItem]?, feedId: Int64) -> [Entry] {
        guard let items else { return [] }
        return items.compactMap { item in
            makeEntry(
                feedId: feedId,
                guid: item.link,
                url: item.link,
                title: item.title,
                author: item.author,
                published: item.pubDate,
                summary: item.description
            )
        }
    }

    private func mapAtomEntries(_ entries: [AtomFeedEntry]?, feedId: Int64) -> [Entry] {
        guard let entries else { return [] }
        return entries.compactMap { entry in
            let url = entry.links?.first?.attributes?.href
            return makeEntry(
                feedId: feedId,
                guid: entry.id,
                url: url,
                title: entry.title,
                author: entry.authors?.first?.name,
                published: entry.published ?? entry.updated,
                summary: nil
            )
        }
    }

    private func mapJSONItems(_ items: [JSONFeedItem]?, feedId: Int64) -> [Entry] {
        guard let items else { return [] }
        return items.compactMap { item in
            makeEntry(
                feedId: feedId,
                guid: item.id,
                url: item.url,
                title: item.title,
                author: item.author?.name,
                published: item.datePublished,
                summary: item.summary
            )
        }
    }

    private func makeEntry(
        feedId: Int64,
        guid: String?,
        url: String?,
        title: String?,
        author: String?,
        published: Date?,
        summary: String?
    ) -> Entry? {
        guard guid != nil || url != nil else { return nil }

        let secureURLString: String?
        if let url, let converted = forceSecureURL(url) {
            secureURLString = converted
        } else {
            secureURLString = url
        }

        return Entry(
            id: nil,
            feedId: feedId,
            guid: guid,
            url: secureURLString,
            title: title,
            author: author,
            publishedAt: published,
            summary: summary,
            isRead: false,
            createdAt: Date()
        )
    }

    private func recalculateUnreadCounts() async throws {
        try await db.write { db in
            let feeds = try Feed.fetchAll(db)
            for var feed in feeds {
                guard let feedId = feed.id else { continue }
                let count = try Entry
                    .filter(Column("feedId") == feedId)
                    .filter(Column("isRead") == false)
                    .fetchCount(db)
                feed.unreadCount = count
                try feed.update(db)
            }
        }
    }

    private func opmlCandidateURLs() -> [URL] {
        var candidates: [URL] = []

        if let bundled = Bundle.main.url(forResource: "hn-popular", withExtension: "opml") {
            candidates.append(bundled)
        }

        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("hn-popular.opml") {
            candidates.append(resourceURL)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Mercury/Resources/hn-popular.opml"))
        candidates.append(cwd.appendingPathComponent("Resources/hn-popular.opml"))

        return candidates
    }

    private func forceSecureURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            return components?.url
        }
        return url
    }

    private func forceSecureURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let secureURL = forceSecureURL(url) else { return nil }
        return secureURL.absoluteString
    }

    private func deleteFeed(_ feed: Feed) async throws {
        try await db.write { db in
            _ = try feed.delete(db)
        }
    }
}

enum SyncError: Error {
    case missingOPML([String])
}

extension SyncError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingOPML(let paths):
            let list = paths.joined(separator: "\n")
            return "OPML not found. Tried:\n\(list)"
        }
    }
}
