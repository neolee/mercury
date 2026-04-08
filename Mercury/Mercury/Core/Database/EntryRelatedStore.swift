import Foundation
import GRDB

/// Temporary related-entry recommendation query module.
///
/// Important:
/// - This implementation is intentionally isolated from the main `EntryQuerySpec` /
///   `EntryQueryBuilder` path.
/// - The current algorithm is only a simple tag-overlap heuristic plus custom ranking SQL.
/// - We expect this area to evolve independently, potentially with a very different retrieval
///   strategy, so it should not shape the main visible-entry query abstraction.
///
/// The only shared contract retained here is visible-entry filtering, reused through
/// `EntryQueryBuilder.visibleSQLPredicate(tableAlias:)` so deleted entries remain globally hidden.
nonisolated enum EntryRelatedStore {
    static func fetchRelatedEntries(
        database: DatabaseManager,
        entryId: Int64,
        limit: Int = 5
    ) async -> [EntryListItem] {
        do {
            return try await database.read { db in
                let visiblePredicate = EntryQueryBuilder.visibleSQLPredicate(tableAlias: "entry")
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
                  AND \(visiblePredicate)
                GROUP BY entry.id
                ORDER BY matchScore DESC, entry.publishedAt DESC, entry.createdAt DESC, entry.id DESC
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
}
