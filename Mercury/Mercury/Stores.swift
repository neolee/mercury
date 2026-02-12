//
//  Stores.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Combine
import Foundation
import GRDB

@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var feeds: [Feed] = []

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func loadAll() async {
        do {
            let values = try await db.read { db in
                try Feed.order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
            }
            feeds = values
        } catch {
            feeds = []
        }
    }

    func upsert(_ feed: Feed) async throws {
        try await db.write { db in
            var mutableFeed = feed
            try mutableFeed.save(db)
        }
        await loadAll()
    }

    func delete(_ feed: Feed) async throws {
        try await db.write { db in
            _ = try feed.delete(db)
        }
        await loadAll()
    }
}

@MainActor
final class EntryStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var entryFeedTitles: [Int64: String] = [:]

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    struct EntryListQuery: Equatable {
        var feedId: Int64?
        var unreadOnly: Bool
        var keepEntryId: Int64?
    }

    func loadAll(for feedId: Int64?, unreadOnly: Bool = false, keepEntryId: Int64? = nil) async {
        await loadAll(query: EntryListQuery(feedId: feedId, unreadOnly: unreadOnly, keepEntryId: keepEntryId))
    }

    func loadAll(query: EntryListQuery) async {
        do {
            let (values, titlesByEntryId) = try await db.read { db in
                var request = Entry.order(Column("publishedAt").desc, Column("createdAt").desc)
                if let feedId = query.feedId {
                    request = request.filter(Column("feedId") == feedId)
                }
                if query.unreadOnly {
                    request = request.filter(Column("isRead") == false)
                }
                var fetchedEntries = try request.fetchAll(db)

                if query.unreadOnly, let keepEntryId = query.keepEntryId,
                   fetchedEntries.contains(where: { $0.id == keepEntryId }) == false,
                   let kept = try Entry.filter(Column("id") == keepEntryId).fetchOne(db) {
                    fetchedEntries.insert(kept, at: 0)
                }

                let feedMap: [Int64: String]
                if query.feedId == nil {
                    let feeds = try Feed.fetchAll(db)
                    feedMap = Dictionary(uniqueKeysWithValues: feeds.compactMap { feed in
                        guard let id = feed.id else { return nil }
                        let title = feed.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return (id, (title?.isEmpty == false ? title! : feed.feedURL))
                    })
                } else {
                    feedMap = [:]
                }

                var titlesByEntryId: [Int64: String] = [:]
                if query.feedId == nil {
                    for entry in fetchedEntries {
                        guard let entryId = entry.id else { continue }
                        if let title = feedMap[entry.feedId] {
                            titlesByEntryId[entryId] = title
                        }
                    }
                }

                return (fetchedEntries, titlesByEntryId)
            }
            entries = values
            entryFeedTitles = titlesByEntryId
        } catch {
            entries = []
            entryFeedTitles = [:]
        }
    }

    func markRead(entryId: Int64, isRead: Bool) async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE entry SET isRead = ? WHERE id = ?",
                arguments: [isRead, entryId]
            )
        }

        if let index = entries.firstIndex(where: { $0.id == entryId }) {
            entries[index].isRead = isRead
        }
    }
}

@MainActor
final class ContentStore: ObservableObject {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func content(for entryId: Int64) async throws -> Content? {
        try await db.read { db in
            try Content.filter(Column("entryId") == entryId).fetchOne(db)
        }
    }

    func upsert(_ content: Content) async throws {
        try await db.write { db in
            var mutableContent = content
            try mutableContent.save(db)
        }
    }

    func cachedHTML(for entryId: Int64, themeId: String) async throws -> ContentHTMLCache? {
        try await db.read { db in
            try ContentHTMLCache
                .filter(Column("entryId") == entryId)
                .filter(Column("themeId") == themeId)
                .fetchOne(db)
        }
    }

    func upsertCache(entryId: Int64, themeId: String, html: String) async throws {
        let cache = ContentHTMLCache(
            entryId: entryId,
            themeId: themeId,
            html: html,
            updatedAt: Date()
        )
        try await db.write { db in
            var mutableCache = cache
            try mutableCache.save(db)
        }
    }
}

@MainActor
extension FeedStore {
    func updateUnreadCount(for feedId: Int64) async throws -> Int {
        let count = try await UnreadCountUseCase(database: db)
            .recalculate(forFeedId: feedId)

        if let index = feeds.firstIndex(where: { $0.id == feedId }) {
            feeds[index].unreadCount = count
        }

        return count
    }

    var totalUnreadCount: Int {
        feeds.reduce(0) { $0 + $1.unreadCount }
    }
}
