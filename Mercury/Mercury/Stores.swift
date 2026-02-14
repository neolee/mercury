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
        var searchText: String?
    }

    func loadAll(for feedId: Int64?, unreadOnly: Bool = false, keepEntryId: Int64? = nil, searchText: String? = nil) async {
        await loadAll(query: EntryListQuery(feedId: feedId, unreadOnly: unreadOnly, keepEntryId: keepEntryId, searchText: searchText))
    }

    func loadAll(query: EntryListQuery) async {
        let trimmedSearchText = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSearchText = (trimmedSearchText?.isEmpty == false) ? trimmedSearchText : nil
        let searchPattern = normalizedSearchText.map { "%\($0)%" }
        let searchResultLimit = (searchPattern == nil) ? nil : 200

        do {
            let values = try await db.read { db in
                var request = Entry.order(Column("publishedAt").desc, Column("createdAt").desc)
                if let feedId = query.feedId {
                    request = request.filter(Column("feedId") == feedId)
                }
                if query.unreadOnly {
                    request = request.filter(Column("isRead") == false)
                }
                if let searchPattern {
                    request = request.filter(
                        sql: "(COALESCE(title, '') LIKE ? COLLATE NOCASE OR COALESCE(summary, '') LIKE ? COLLATE NOCASE)",
                        arguments: [searchPattern, searchPattern]
                    )
                }
                if let searchResultLimit {
                    request = request.limit(searchResultLimit)
                }
                var fetchedEntries = try request.fetchAll(db)

                if query.unreadOnly,
                   normalizedSearchText == nil,
                   let keepEntryId = query.keepEntryId,
                   fetchedEntries.contains(where: { $0.id == keepEntryId }) == false,
                   let kept = try Entry.filter(Column("id") == keepEntryId).fetchOne(db) {
                    fetchedEntries.insert(kept, at: 0)
                }

                return fetchedEntries
            }
            entries = values
            entryFeedTitles = [:]
        } catch {
            entries = []
            entryFeedTitles = [:]
        }
    }

    func setFeedTitlesByEntryId(_ values: [Int64: String]) {
        entryFeedTitles = values
    }

    func clearFeedTitles() {
        entryFeedTitles = [:]
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

    func markRead(entryIds: [Int64], isRead: Bool) async throws {
        guard entryIds.isEmpty == false else { return }

        let uniqueEntryIds = Array(Set(entryIds))
        let chunkSize = 300
        let readValue = isRead ? 1 : 0

        try await db.write { db in
            for start in stride(from: 0, to: uniqueEntryIds.count, by: chunkSize) {
                let end = min(start + chunkSize, uniqueEntryIds.count)
                let chunk = Array(uniqueEntryIds[start..<end])
                let idList = chunk.map(String.init).joined(separator: ",")
                try db.execute(sql: "UPDATE entry SET isRead = \(readValue) WHERE id IN (\(idList))")
            }
        }

        let updatedIdSet = Set(uniqueEntryIds)
        for index in entries.indices {
            if let id = entries[index].id, updatedIdSet.contains(id) {
                entries[index].isRead = isRead
            }
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

    func updateUnreadCounts(for feedIds: [Int64]) async throws {
        for feedId in Set(feedIds) {
            _ = try await updateUnreadCount(for: feedId)
        }
    }
}
