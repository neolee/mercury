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
    @Published private(set) var entries: [EntryListItem] = []

    private let db: DatabaseManager

    static let defaultBatchSize = 200

    init(db: DatabaseManager) {
        self.db = db
    }

    struct EntryListCursor: Equatable {
        var publishedAt: Date?
        var createdAt: Date
        var id: Int64
    }

    struct EntryListPage {
        var hasMore: Bool
        var nextCursor: EntryListCursor?
    }

    struct EntryListQuery: Equatable {
        var feedId: Int64?
        var unreadOnly: Bool
        var keepEntryId: Int64?
        var searchText: String?
    }

    func loadAll(for feedId: Int64?, unreadOnly: Bool = false, keepEntryId: Int64? = nil, searchText: String? = nil) async {
        _ = await loadFirstPage(
            query: EntryListQuery(
                feedId: feedId,
                unreadOnly: unreadOnly,
                keepEntryId: keepEntryId,
                searchText: searchText
            )
        )
    }

    func loadFirstPage(query: EntryListQuery, batchSize: Int = EntryStore.defaultBatchSize) async -> EntryListPage {
        await loadPage(query: query, cursor: nil, batchSize: batchSize, append: false)
    }

    func loadNextPage(
        query: EntryListQuery,
        after cursor: EntryListCursor,
        batchSize: Int = EntryStore.defaultBatchSize
    ) async -> EntryListPage {
        await loadPage(query: query, cursor: cursor, batchSize: batchSize, append: true)
    }

    private func loadPage(
        query: EntryListQuery,
        cursor: EntryListCursor?,
        batchSize: Int,
        append: Bool
    ) async -> EntryListPage {
        let trimmedSearchText = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSearchText = (trimmedSearchText?.isEmpty == false) ? trimmedSearchText : nil
        let searchPattern = normalizedSearchText.map { "%\($0)%" }
        let effectiveBatchSize = max(batchSize, 1)
        let fetchLimit = effectiveBatchSize + 1

        do {
            let result = try await db.read { db in
                var sql = """
                SELECT
                    entry.id,
                    entry.feedId,
                    entry.title,
                    entry.publishedAt,
                    entry.createdAt,
                    entry.isRead,
                    COALESCE(NULLIF(TRIM(feed.title), ''), feed.feedURL) AS feedSourceTitle
                FROM entry
                JOIN feed ON feed.id = entry.feedId
                """

                var conditions: [String] = []
                var arguments: StatementArguments = []

                if let feedId = query.feedId {
                    conditions.append("entry.feedId = ?")
                    arguments += [feedId]
                }
                if query.unreadOnly {
                    conditions.append("entry.isRead = 0")
                }
                if let searchPattern {
                    conditions.append("(COALESCE(entry.title, '') LIKE ? COLLATE NOCASE OR COALESCE(entry.summary, '') LIKE ? COLLATE NOCASE)")
                    arguments += [searchPattern, searchPattern]
                }
                if let cursor {
                    if let cursorPublishedAt = cursor.publishedAt {
                        conditions.append("""
                        (
                            entry.publishedAt < ?
                            OR (
                                entry.publishedAt = ?
                                AND (
                                    entry.createdAt < ?
                                    OR (entry.createdAt = ? AND entry.id < ?)
                                )
                            )
                            OR entry.publishedAt IS NULL
                        )
                        """)
                        arguments += [
                            cursorPublishedAt,
                            cursorPublishedAt,
                            cursor.createdAt,
                            cursor.createdAt,
                            cursor.id
                        ]
                    } else {
                        conditions.append("""
                        (
                            entry.publishedAt IS NULL
                            AND (
                                entry.createdAt < ?
                                OR (entry.createdAt = ? AND entry.id < ?)
                            )
                        )
                        """)
                        arguments += [cursor.createdAt, cursor.createdAt, cursor.id]
                    }
                }

                if conditions.isEmpty == false {
                    sql += "\nWHERE " + conditions.joined(separator: " AND ")
                }

                sql += "\nORDER BY entry.publishedAt DESC, entry.createdAt DESC, entry.id DESC"
                sql += "\nLIMIT ?"
                arguments += [fetchLimit]

                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
                var fetchedEntries = rows.compactMap { row -> EntryListItem? in
                    guard let id: Int64 = row["id"] else { return nil }
                    let feedId: Int64 = row["feedId"]
                    let title: String? = row["title"]
                    let publishedAt: Date? = row["publishedAt"]
                    let createdAt: Date = row["createdAt"]
                    let isRead: Bool = row["isRead"]
                    let feedSourceTitle: String? = row["feedSourceTitle"]
                    return EntryListItem(
                        id: id,
                        feedId: feedId,
                        title: title,
                        publishedAt: publishedAt,
                        createdAt: createdAt,
                        isRead: isRead,
                        feedSourceTitle: feedSourceTitle
                    )
                }

                if query.unreadOnly,
                   cursor == nil,
                   normalizedSearchText == nil,
                   let keepEntryId = query.keepEntryId,
                   fetchedEntries.contains(where: { $0.id == keepEntryId }) == false,
                   let keptRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT
                        entry.id,
                        entry.feedId,
                        entry.title,
                        entry.publishedAt,
                        entry.createdAt,
                        entry.isRead,
                        COALESCE(NULLIF(TRIM(feed.title), ''), feed.feedURL) AS feedSourceTitle
                    FROM entry
                    JOIN feed ON feed.id = entry.feedId
                    WHERE entry.id = ?
                    LIMIT 1
                    """,
                    arguments: [keepEntryId]
                   ) {
                    let id: Int64 = keptRow["id"]
                    let feedId: Int64 = keptRow["feedId"]
                    let title: String? = keptRow["title"]
                    let publishedAt: Date? = keptRow["publishedAt"]
                    let createdAt: Date = keptRow["createdAt"]
                    let isRead: Bool = keptRow["isRead"]
                    let feedSourceTitle: String? = keptRow["feedSourceTitle"]
                    fetchedEntries.insert(
                        EntryListItem(
                            id: id,
                            feedId: feedId,
                            title: title,
                            publishedAt: publishedAt,
                            createdAt: createdAt,
                            isRead: isRead,
                            feedSourceTitle: feedSourceTitle
                        ),
                        at: 0
                    )
                }

                let hasMore = fetchedEntries.count > effectiveBatchSize
                if hasMore {
                    fetchedEntries = Array(fetchedEntries.prefix(effectiveBatchSize))
                }

                let nextCursor: EntryListCursor? = fetchedEntries.last.map { item in
                    EntryListCursor(
                        publishedAt: item.publishedAt,
                        createdAt: item.createdAt,
                        id: item.id
                    )
                }

                return (fetchedEntries, hasMore, nextCursor)
            }
            let fetchedEntries = result.0
            let hasMore = result.1
            let nextCursor = result.2

            if append {
                entries.append(contentsOf: fetchedEntries)
            } else {
                entries = fetchedEntries
            }
            return EntryListPage(hasMore: hasMore, nextCursor: nextCursor)
        } catch {
            if append == false {
                entries = []
            }
            return EntryListPage(hasMore: false, nextCursor: nil)
        }
    }

    func loadEntry(id: Int64) async -> Entry? {
        do {
            return try await db.read { db in
                try Entry.filter(Column("id") == id).fetchOne(db)
            }
        } catch {
            return nil
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
            let id = entries[index].id
            if updatedIdSet.contains(id) {
                entries[index].isRead = isRead
            }
        }
    }

    func markRead(query: EntryListQuery, isRead: Bool) async throws -> [Int64] {
        let trimmedSearchText = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSearchText = (trimmedSearchText?.isEmpty == false) ? trimmedSearchText : nil
        let searchPattern = normalizedSearchText.map { "%\($0)%" }
        let readValue = isRead ? 1 : 0

        return try await db.write { db in
            var conditions: [String] = []
            var arguments: StatementArguments = []

            if let feedId = query.feedId {
                conditions.append("entry.feedId = ?")
                arguments += [feedId]
            }
            if query.unreadOnly {
                conditions.append("entry.isRead = 0")
            }
            if let searchPattern {
                conditions.append("(COALESCE(entry.title, '') LIKE ? COLLATE NOCASE OR COALESCE(entry.summary, '') LIKE ? COLLATE NOCASE)")
                arguments += [searchPattern, searchPattern]
            }

            let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            let feedRows = try Row.fetchAll(
                db,
                sql: "SELECT DISTINCT entry.feedId AS feedId FROM entry" + whereClause,
                arguments: arguments
            )
            let affectedFeedIds = feedRows.compactMap { row -> Int64? in
                row["feedId"]
            }

            try db.execute(
                sql: "UPDATE entry SET isRead = ?" + whereClause,
                arguments: [readValue] + arguments
            )

            return affectedFeedIds
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
