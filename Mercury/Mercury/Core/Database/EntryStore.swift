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

        var querySpec: EntryQuerySpec {
            EntryQuerySpec(
                feedId: feedId,
                unreadOnly: unreadOnly,
                starredOnly: starredOnly,
                searchText: searchText,
                tagIds: tagIds,
                tagMatchMode: tagMatchMode
            )
        }
    }

    enum TagMatchMode: String, Equatable {
        case any
        case all
    }

    private struct EntryListFetchRecord: FetchableRecord, Decodable {
        var id: Int64
        var feedId: Int64
        var title: String?
        var publishedAt: Date?
        var createdAt: Date
        var isRead: Bool
        var isStarred: Bool
        var feedTitle: String?
        var feedURL: String

        var listItem: EntryListItem {
            let trimmedFeedTitle = feedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let feedSourceTitle = (trimmedFeedTitle?.isEmpty == false) ? trimmedFeedTitle : feedURL
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
    }

    private nonisolated static func makeEntryListProjectionRequest(
        from request: QueryInterfaceRequest<Entry>,
        limit: Int? = nil
    ) -> some FetchRequest<EntryListFetchRecord> {
        var request = request
            .select(
                Column("id"),
                Column("feedId"),
                Column("title"),
                Column("publishedAt"),
                Column("createdAt"),
                Column("isRead"),
                Column("isStarred")
            )
            .annotated(
                withRequired: Entry.feed.select(
                    Column("title").forKey("feedTitle"),
                    Column("feedURL").forKey("feedURL")
                )
            )
            .order(
                Column("publishedAt").desc,
                Column("createdAt").desc,
                Column("id").desc
            )

        if let limit {
            request = request.limit(limit)
        }

        return request.asRequest(of: EntryListFetchRecord.self)
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
        let normalizedSearchText = EntryQueryBuilder.normalizedSearchText(from: query.searchText)
        let effectiveBatchSize = max(batchSize, 1)
        let fetchLimit = effectiveBatchSize + 1

        do {
            let result = try await db.read { db in
                let selectionRequest = EntryQueryBuilder.buildVisibleEntries(spec: query.querySpec)
                let baseRequest = if let cursor {
                    EntryQueryBuilder.applyListCursor(cursor, to: selectionRequest)
                } else {
                    selectionRequest
                }
                let records = try Self.makeEntryListProjectionRequest(
                    from: baseRequest,
                    limit: fetchLimit
                ).fetchAll(db)
                var fetchedEntries = records.map(\.listItem)

                if query.unreadOnly,
                   cursor == nil,
                   normalizedSearchText == nil,
                   let keepEntryId = query.keepEntryId,
                   fetchedEntries.contains(where: { $0.id == keepEntryId }) == false,
                   let keptRecord = try Self.makeEntryListProjectionRequest(
                    from: EntryQueryBuilder.buildVisibleEntry(id: keepEntryId)
                        .limit(1)
                   ).fetchOne(db) {
                    fetchedEntries.insert(keptRecord.listItem, at: 0)
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
                try EntryQueryBuilder
                    .buildVisibleEntry(id: id)
                    .fetchOne(db)
            }
        } catch {
            return nil
        }
    }

    func markRead(entryId: Int64, isRead: Bool) async throws {
        try await db.write { db in
            _ = try EntryQueryBuilder
                .buildVisibleEntry(id: entryId)
                .updateAll(db, Column("isRead").set(to: isRead))
        }

        if let index = entries.firstIndex(where: { $0.id == entryId }) {
            entries[index].isRead = isRead
        }
    }

    func markStarred(entryId: Int64, isStarred: Bool) async throws {
        try await db.write { db in
            _ = try EntryQueryBuilder
                .buildVisibleEntry(id: entryId)
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

    func updateURL(entryId: Int64, url: String) async throws {
        try await db.write { db in
            _ = try EntryQueryBuilder
                .buildVisibleEntry(id: entryId)
                .updateAll(db, Column("url").set(to: url))
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
                _ = try EntryQueryBuilder
                    .buildVisibleEntries(ids: chunk)
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
        return try await db.write { db in
            let request = EntryQueryBuilder.buildVisibleEntries(spec: query.querySpec)
            let affectedFeedIds = try Int64.fetchAll(
                db,
                request
                    .select(Column("feedId"))
                    .distinct()
            )
            _ = try request.updateAll(db, Column("isRead").set(to: isRead))
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
        do {
            return try await db.read { db in
                try EntryQueryBuilder.fetchUnreadCountsByTagIDs(tagIds, db: db)
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
            try TagMutationPolicy.assertNoActiveBatchLifecycle(db)

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
            try TagMutationPolicy.assertNoActiveBatchLifecycle(db)
            try TagMutationPolicy.deleteTagRows(id: id, db: db)
        }
    }

    func fetchRelatedEntries(for entryId: Int64, limit: Int = 5) async -> [EntryListItem] {
        await EntryRelatedStore.fetchRelatedEntries(database: db, entryId: entryId, limit: limit)
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
    /// The supplied alias collides with an existing alias.
    case aliasAlreadyExists
    /// The supplied alias normalizes to the selected tag's canonical name.
    case aliasMatchesCanonicalName
    /// A batch tagging run is active and destructive tag mutations are temporarily blocked.
    case batchRunActive
    /// The requested tag row no longer exists.
    case tagNotFound
    /// Merge requires distinct source and target tags.
    case cannotMergeIntoSelf
}
