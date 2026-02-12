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
    private let jobRunner: JobRunner

    init(db: DatabaseManager, jobRunner: JobRunner) {
        self.db = db
        self.jobRunner = jobRunner
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

    func syncFeed(withId feedId: Int64) async throws {
        guard let feed = try await db.read({ db in
            try Feed.filter(Column("id") == feedId).fetchOne(db)
        }) else { return }

        try await sync(feed)
        try await recalculateUnreadCount(for: feedId)
    }

    func syncFeeds(withIds feedIds: [Int64]) async throws {
        guard feedIds.isEmpty == false else { return }
        let feeds = try await db.read { db in
            let allFeeds = try Feed.fetchAll(db)
            let idSet = Set(feedIds)
            return allFeeds.filter { feed in
                guard let feedId = feed.id else { return false }
                return idSet.contains(feedId)
            }
        }

        for feed in feeds {
            guard let feedId = feed.id else { continue }
            do {
                try await sync(feed)
                try await recalculateUnreadCount(for: feedId)
            } catch {
                continue
            }
        }
    }

    func fetchFeedTitle(from urlString: String) async throws -> String? {
        guard let url = URL(string: urlString) else { return nil }

        let parsedFeed = try await loadFeed(from: url)
        switch parsedFeed {
        case .rss(let rss):
            return rss.channel?.title
        case .atom(let atom):
            return atom.title?.text
        case .json(let json):
            return json.title
        }
    }

    private func sync(_ feed: Feed) async throws {
        guard let feedId = feed.id else { return }
        guard let url = URL(string: feed.feedURL) else { return }

        let parsedFeed = try await loadFeed(from: url)
        let entries = mapEntries(feed: parsedFeed, feedId: feedId, baseURLString: feed.siteURL ?? feed.feedURL)

        try await db.write { db in
            for var entry in entries {
                try entry.insert(db, onConflict: .ignore)
            }

            var updated = feed
            updated.lastFetchedAt = Date()
            try updated.update(db)
        }
    }

    private func mapEntries(feed: FeedKit.Feed, feedId: Int64, baseURLString: String?) -> [Entry] {
        switch feed {
        case .rss(let rss):
            return mapRSSItems(rss.channel?.items, feedId: feedId, baseURLString: baseURLString)
        case .atom(let atom):
            return mapAtomEntries(atom.entries, feedId: feedId, baseURLString: baseURLString)
        case .json(let json):
            return mapJSONItems(json.items, feedId: feedId, baseURLString: baseURLString)
        }
    }

    private func mapRSSItems(_ items: [RSSFeedItem]?, feedId: Int64, baseURLString: String?) -> [Entry] {
        guard let items else { return [] }
        return items.compactMap { item in
            makeEntry(
                feedId: feedId,
                guid: item.link,
                url: normalizeEntryURL(item.link, baseURLString: baseURLString),
                title: item.title,
                author: item.author,
                published: item.pubDate,
                summary: item.description
            )
        }
    }

    private func mapAtomEntries(_ entries: [AtomFeedEntry]?, feedId: Int64, baseURLString: String?) -> [Entry] {
        guard let entries else { return [] }
        return entries.compactMap { entry in
            let url = normalizeEntryURL(entry.links?.first?.attributes?.href, baseURLString: baseURLString)
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

    private func mapJSONItems(_ items: [JSONFeedItem]?, feedId: Int64, baseURLString: String?) -> [Entry] {
        guard let items else { return [] }
        return items.compactMap { item in
            makeEntry(
                feedId: feedId,
                guid: item.id,
                url: normalizeEntryURL(item.url, baseURLString: baseURLString),
                title: item.title,
                author: item.author?.name,
                published: item.datePublished,
                summary: item.summary
            )
        }
    }

    private func loadFeed(from url: URL) async throws -> FeedKit.Feed {
        try await jobRunner.run(label: "feedFetch", timeout: 20) { report in
            report("begin")
            let feed = try await FeedKit.Feed(url: url)
            report("ok")
            return feed
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
        try await UnreadCountUseCase(database: db)
            .recalculateAll()
    }

    private func recalculateUnreadCount(for feedId: Int64) async throws {
        _ = try await UnreadCountUseCase(database: db)
            .recalculate(forFeedId: feedId)
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

    private func normalizeEntryURL(_ urlString: String?, baseURLString: String?) -> String? {
        guard let urlString, urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("//") {
            return "https:\(trimmed)"
        }

        if let url = URL(string: trimmed), url.scheme != nil {
            return forceSecureURL(url)?.absoluteString ?? url.absoluteString
        }

        if let baseURLString, let baseURL = URL(string: baseURLString) {
            if let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                return forceSecureURL(resolved)?.absoluteString ?? resolved.absoluteString
            }
        }

        if trimmed.contains(".") {
            return "https://\(trimmed)"
        }

        return trimmed
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
