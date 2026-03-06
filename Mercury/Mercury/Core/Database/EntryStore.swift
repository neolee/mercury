//
//  EntryStore.swift
//  Mercury
//

import Combine
import Foundation
import GRDB

@MainActor
final class EntryStore: ObservableObject {
    @Published private(set) var entries: [EntryListItem] = []

    private let db: DatabaseManager
    private var currentQuery: EntryListQuery?

    nonisolated static let defaultBatchSize = 200

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
        var starredOnly: Bool = false
        var keepEntryId: Int64?
        var searchText: String?
        var tagIds: Set<Int64>? = nil
        var tagMatchMode: TagMatchMode = .any
    }

    enum TagMatchMode: String, Equatable {
        case any
        case all
    }

    func loadAll(for feedId: Int64?, unreadOnly: Bool = false, keepEntryId: Int64? = nil, searchText: String? = nil) async {
        _ = await loadFirstPage(
            query: EntryListQuery(
                feedId: feedId,
                unreadOnly: unreadOnly,
                starredOnly: false,
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
                    entry.isStarred,
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
                if query.starredOnly {
                    conditions.append("entry.isStarred = 1")
                }
                let queryTagIds = query.tagIds?.sorted() ?? []
                if queryTagIds.isEmpty == false {
                    switch query.tagMatchMode {
                    case .any:
                        let placeholders = Array(repeating: "?", count: queryTagIds.count).joined(separator: ",")
                        conditions.append("entry.id IN (SELECT entryId FROM entry_tag WHERE tagId IN (\(placeholders)))")
                        for tagId in queryTagIds {
                            arguments += [tagId]
                        }
                    case .all:
                        for tagId in queryTagIds {
                            conditions.append("entry.id IN (SELECT entryId FROM entry_tag WHERE tagId = ?)")
                            arguments += [tagId]
                        }
                    }
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
                    let isStarred: Bool = row["isStarred"]
                    let feedSourceTitle: String? = row["feedSourceTitle"]
                    return EntryListItem(
                        id: id,
                        feedId: feedId,
                        title: title,
                        publishedAt: publishedAt,
                        createdAt: createdAt,
                        isRead: isRead,
                        isStarred: isStarred,
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
                        entry.isStarred,
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
                    let isStarred: Bool = keptRow["isStarred"]
                    let feedSourceTitle: String? = keptRow["feedSourceTitle"]
                    fetchedEntries.insert(
                        EntryListItem(
                            id: id,
                            feedId: feedId,
                            title: title,
                            publishedAt: publishedAt,
                            createdAt: createdAt,
                            isRead: isRead,
                            isStarred: isStarred,
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
            currentQuery = query
            return EntryListPage(hasMore: hasMore, nextCursor: nextCursor)
        } catch {
            if append == false {
                entries = []
            }
            currentQuery = query
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
            _ = try Entry
                .filter(Column("id") == entryId)
                .updateAll(db, Column("isRead").set(to: isRead))
        }

        if let index = entries.firstIndex(where: { $0.id == entryId }) {
            entries[index].isRead = isRead
        }
    }

    func markStarred(entryId: Int64, isStarred: Bool) async throws {
        try await db.write { db in
            _ = try Entry
                .filter(Column("id") == entryId)
                .updateAll(db, Column("isStarred").set(to: isStarred))
        }

        guard let index = entries.firstIndex(where: { $0.id == entryId }) else {
            return
        }

        entries[index].isStarred = isStarred
        if currentQuery?.starredOnly == true, isStarred == false {
            entries.remove(at: index)
        }
    }

    func markRead(entryIds: [Int64], isRead: Bool) async throws {
        guard entryIds.isEmpty == false else { return }

        let uniqueEntryIds = Array(Set(entryIds))
        let chunkSize = 300
        try await db.write { db in
            for start in stride(from: 0, to: uniqueEntryIds.count, by: chunkSize) {
                let end = min(start + chunkSize, uniqueEntryIds.count)
                let chunk = Array(uniqueEntryIds[start..<end])
                _ = try Entry
                    .filter(chunk.contains(Column("id")))
                    .updateAll(db, Column("isRead").set(to: isRead))
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
            if query.starredOnly {
                conditions.append("entry.isStarred = 1")
            }
            let queryTagIds = query.tagIds?.sorted() ?? []
            if queryTagIds.isEmpty == false {
                switch query.tagMatchMode {
                case .any:
                    let placeholders = Array(repeating: "?", count: queryTagIds.count).joined(separator: ",")
                    conditions.append("entry.id IN (SELECT entryId FROM entry_tag WHERE tagId IN (\(placeholders)))")
                    for tagId in queryTagIds {
                        arguments += [tagId]
                    }
                case .all:
                    for tagId in queryTagIds {
                        conditions.append("entry.id IN (SELECT entryId FROM entry_tag WHERE tagId = ?)")
                        arguments += [tagId]
                    }
                }
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

    func assignTags(to entryId: Int64, names: [String], source: String) async throws {
        let normalizedPairs = Self.normalizedTagPairs(from: names)
        guard normalizedPairs.isEmpty == false else { return }

        try await db.write { db in
            for (normalizedName, displayName) in normalizedPairs {
                let tagId: Int64
                if let existingTagId = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM tag WHERE normalizedName = ? LIMIT 1",
                    arguments: [normalizedName]
                ) {
                    tagId = existingTagId
                } else {
                    var tag = Tag(
                        id: nil,
                        name: displayName,
                        normalizedName: normalizedName,
                        isProvisional: true,
                        usageCount: 0
                    )
                    try tag.insert(db)
                    guard let insertedId = tag.id else { continue }
                    tagId = insertedId
                }

                try db.execute(
                    sql: """
                    INSERT INTO entry_tag (entryId, tagId, source, confidence)
                    VALUES (?, ?, ?, NULL)
                    ON CONFLICT(entryId, tagId) DO NOTHING
                    """,
                    arguments: [entryId, tagId, source]
                )

                guard db.changesCount > 0 else { continue }

                try db.execute(
                    sql: "UPDATE tag SET usageCount = usageCount + 1 WHERE id = ?",
                    arguments: [tagId]
                )
                try db.execute(
                    sql: "UPDATE tag SET isProvisional = 0 WHERE id = ? AND usageCount >= ?",
                    arguments: [tagId, TaggingPolicy.provisionalPromotionThreshold]
                )
            }
        }
    }

    func fetchTags(includeProvisional: Bool, searchText: String? = nil) async -> [Tag] {
        let trimmedSearchText = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSearchText = (trimmedSearchText?.isEmpty == false) ? trimmedSearchText : nil
        let searchPattern = normalizedSearchText.map { "%\($0)%" }

        do {
            return try await db.read { db in
                var sql = "SELECT id, name, normalizedName, isProvisional, usageCount FROM tag"
                var conditions: [String] = []
                var arguments: StatementArguments = []

                if includeProvisional == false {
                    conditions.append("isProvisional = 0")
                }
                if let searchPattern {
                    conditions.append("(name LIKE ? COLLATE NOCASE OR normalizedName LIKE ? COLLATE NOCASE)")
                    arguments += [searchPattern, searchPattern]
                }

                if conditions.isEmpty == false {
                    sql += " WHERE " + conditions.joined(separator: " AND ")
                }
                sql += " ORDER BY usageCount DESC, normalizedName ASC"

                return try Tag.fetchAll(db, sql: sql, arguments: arguments)
            }
        } catch {
            return []
        }
    }

    func fetchTags(for entryId: Int64) async -> [Tag] {
        do {
            return try await db.read { db in
                try Tag.fetchAll(
                    db,
                    sql: """
                    SELECT t.id, t.name, t.normalizedName, t.isProvisional, t.usageCount
                    FROM tag t
                    JOIN entry_tag et ON et.tagId = t.id
                    WHERE et.entryId = ?
                    ORDER BY t.normalizedName ASC
                    """,
                    arguments: [entryId]
                )
            }
        } catch {
            return []
        }
    }

    func fetchUnreadCountByTagIds(_ tagIds: [Int64]) async -> [Int64: Int] {
        guard tagIds.isEmpty == false else { return [:] }

        let uniqueTagIds = Array(Set(tagIds)).sorted()
        let placeholders = Array(repeating: "?", count: uniqueTagIds.count).joined(separator: ",")

        do {
            return try await db.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT et.tagId AS tagId, COUNT(e.id) AS unreadCount
                    FROM entry_tag et
                    JOIN entry e ON e.id = et.entryId
                    WHERE e.isRead = 0 AND et.tagId IN (
                    \(placeholders)
                    )
                    GROUP BY et.tagId
                    """,
                    arguments: StatementArguments(uniqueTagIds)
                )

                var result: [Int64: Int] = [:]
                for row in rows {
                    guard let tagId: Int64 = row["tagId"] else { continue }
                    let unreadCount: Int = row["unreadCount"] ?? 0
                    result[tagId] = unreadCount
                }
                return result
            }
        } catch {
            return [:]
        }
    }

    func removeTag(from entryId: Int64, tagId: Int64) async throws {
        try await db.write { db in
            try db.execute(
                sql: "DELETE FROM entry_tag WHERE entryId = ? AND tagId = ?",
                arguments: [entryId, tagId]
            )

            guard db.changesCount > 0 else { return }

            try db.execute(
                sql: "UPDATE tag SET usageCount = MAX(usageCount - 1, 0) WHERE id = ?",
                arguments: [tagId]
            )
            try db.execute(
                sql: "UPDATE tag SET isProvisional = 1 WHERE id = ? AND usageCount < ?",
                arguments: [tagId, TaggingPolicy.provisionalPromotionThreshold]
            )
        }
    }

    // MARK: - Tag Mutation

    /// Renames a tag to a new display name.
    ///
    /// The tag row's `name` and `normalizedName` are updated atomically.
    /// Fails with `TagMutationError.nameAlreadyExists` if another tag already has the same
    /// normalized form, and with `TagMutationError.emptyName` if `newName` is blank.
    func renameTag(id: Int64, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw TagMutationError.emptyName }
        let normalized = TagNormalization.normalize(trimmed)
        guard normalized.isEmpty == false else { throw TagMutationError.emptyName }

        try await db.write { db in
            let hasActiveBatchRun = try TagBatchRun
                .filter(TagBatchRunStatus.activeLifecycleRawValues.contains(Column("status")))
                .fetchCount(db) > 0
            if hasActiveBatchRun {
                throw TagMutationError.batchRunActive
            }

            let collision = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tag WHERE normalizedName = ? AND id != ? LIMIT 1",
                arguments: [normalized, id]
            )
            if collision != nil { throw TagMutationError.nameAlreadyExists }

            try db.execute(
                sql: "UPDATE tag SET name = ?, normalizedName = ? WHERE id = ?",
                arguments: [trimmed, normalized, id]
            )
        }
    }

    /// Deletes a tag and removes all of its associated `entry_tag` and `tag_alias` rows.
    ///
    /// The caller is responsible for removing the deleted tag ID from any active selection state.
    func deleteTag(id: Int64) async throws {
        try await db.write { db in
            let hasActiveBatchRun = try TagBatchRun
                .filter(TagBatchRunStatus.activeLifecycleRawValues.contains(Column("status")))
                .fetchCount(db) > 0
            if hasActiveBatchRun {
                throw TagMutationError.batchRunActive
            }

            try db.execute(sql: "DELETE FROM entry_tag WHERE tagId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM tag_alias WHERE tagId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Related Entries

    /// Returns entries that share the most tags with the given entry, ranked by co-occurrence count.
    func fetchRelatedEntries(for entryId: Int64, limit: Int = 5) async -> [EntryListItem] {
        do {
            return try await db.read { db in
                let sql = """
                SELECT entry.id, entry.feedId, entry.title, entry.publishedAt,
                       entry.createdAt, entry.isRead, entry.isStarred,
                       COALESCE(NULLIF(TRIM(feed.title), ''), feed.feedURL) AS feedSourceTitle,
                       COUNT(et.tagId) AS matchScore
                FROM entry
                JOIN entry_tag et ON entry.id = et.entryId
                JOIN feed ON feed.id = entry.feedId
                WHERE et.tagId IN (SELECT tagId FROM entry_tag WHERE entryId = ?)
                  AND entry.id != ?
                GROUP BY entry.id
                ORDER BY matchScore DESC, entry.publishedAt DESC
                LIMIT ?
                """
                let rows = try Row.fetchAll(db, sql: sql, arguments: [entryId, entryId, limit])
                return rows.compactMap { row -> EntryListItem? in
                    guard let id: Int64 = row["id"] else { return nil }
                    return EntryListItem(
                        id: id,
                        feedId: row["feedId"] ?? 0,
                        title: row["title"],
                        publishedAt: row["publishedAt"],
                        createdAt: row["createdAt"] ?? Date(),
                        isRead: row["isRead"] ?? false,
                        isStarred: row["isStarred"] ?? false,
                        feedSourceTitle: row["feedSourceTitle"]
                    )
                }
            }
        } catch {
            return []
        }
    }

    nonisolated private static func normalizedTagPairs(from names: [String]) -> [(String, String)] {
        var orderedPairs: [(String, String)] = []
        var seenNormalizedNames: Set<String> = []

        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            let normalized = TagNormalization.normalize(trimmed)
            guard normalized.isEmpty == false else { continue }
            guard seenNormalizedNames.contains(normalized) == false else { continue }

            seenNormalizedNames.insert(normalized)
            orderedPairs.append((normalized, trimmed))
        }

        return orderedPairs
    }
}

// MARK: - Tag Mutation Errors

/// Errors thrown by `EntryStore` tag mutation operations.
enum TagMutationError: Error, Equatable, Sendable {
    /// The supplied name is blank after trimming whitespace.
    case emptyName
    /// A different tag with the same normalized name already exists.
    case nameAlreadyExists
    /// A batch tagging run is active and destructive tag mutations are temporarily blocked.
    case batchRunActive
}
