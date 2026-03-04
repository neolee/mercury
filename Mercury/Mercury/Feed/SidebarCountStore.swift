//
//  SidebarCountStore.swift
//  Mercury
//

import Combine
import Foundation
import GRDB

/// Observable store that owns a single GRDB `ValueObservation` and publishes a complete
/// `SidebarProjection`. Any database mutation affecting unread state, starred state, or tag
/// associations automatically triggers a projection update.
///
/// This store is observation-only and performs no writes.
@MainActor
final class SidebarCountStore: ObservableObject {

    @Published private(set) var projection: SidebarProjection = .empty

    private let database: DatabaseManager
    private var observation: AnyDatabaseCancellable?

    init(database: DatabaseManager) {
        self.database = database
        startObservation()
    }

    func stopObservation() {
        observation = nil
    }

    // MARK: - Observation

    private func startObservation() {
        observation = ValueObservation
            .tracking { db in
                try SidebarCountStore.fetchProjection(db)
            }
            .start(
                in: database.dbQueue,
                scheduling: .async(onQueue: .main),
                onError: { error in
                    print("[SidebarCountStore] Observation error: \(error)")
                },
                onChange: { [weak self] newProjection in
                    Task { @MainActor [weak self] in
                        self?.projection = newProjection
                    }
                }
            )
    }

    // MARK: - Projection query

    /// Reads all sidebar counter data from the database in a single tracking read.
    ///
    /// Tables observed (read within this function):
    /// - `entry`: all count computations
    /// - `feed`: tracked so projection fires on feed insertion/deletion
    /// - `tag`: tag rows and visibility computation
    /// - `entry_tag`: join for per-tag unread counts
    nonisolated static func fetchProjection(_ db: Database) throws -> SidebarProjection {

        // Aggregate entry counts.
        let totalUnread = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE isRead = 0") ?? 0
        let totalStarred = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE isStarred = 1") ?? 0
        let starredUnread = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM entry WHERE isStarred = 1 AND isRead = 0"
        ) ?? 0

        // Track the feed table so the observation fires when feeds are added or removed.
        // Per-feed unread counts are derived from the entry table (source of truth).
        let _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed") ?? 0

        let perFeedRows = try Row.fetchAll(
            db,
            sql: "SELECT feedId, COUNT(*) AS unreadCount FROM entry WHERE isRead = 0 GROUP BY feedId"
        )
        var feedUnreadCounts: [Int64: Int] = [:]
        for row in perFeedRows {
            guard let feedId: Int64 = row["feedId"] else { continue }
            feedUnreadCounts[feedId] = row["unreadCount"] ?? 0
        }

        // All tags, ordered by usageCount DESC then normalizedName ASC.
        let tagRows = try Row.fetchAll(
            db,
            sql: "SELECT id, name, normalizedName, isProvisional, usageCount FROM tag ORDER BY usageCount DESC, normalizedName ASC"
        )

        // Per-tag unread counts (only for tags that exist).
        var unreadCountByTagId: [Int64: Int] = [:]
        let allTagIds: [Int64] = tagRows.compactMap { row in row["id"] }
        if allTagIds.isEmpty == false {
            let placeholders = Array(repeating: "?", count: allTagIds.count).joined(separator: ", ")
            let unreadRows = try Row.fetchAll(
                db,
                sql: """
                SELECT et.tagId AS tagId, COUNT(e.id) AS unreadCount
                FROM entry_tag et
                JOIN entry e ON e.id = et.entryId
                WHERE e.isRead = 0 AND et.tagId IN (\(placeholders))
                GROUP BY et.tagId
                """,
                arguments: StatementArguments(allTagIds)
            )
            for row in unreadRows {
                guard let tagId: Int64 = row["tagId"] else { continue }
                unreadCountByTagId[tagId] = row["unreadCount"] ?? 0
            }
        }

        let allTagItems: [SidebarTagItem] = tagRows.compactMap { row -> SidebarTagItem? in
            guard let tagId: Int64 = row["id"] else { return nil }
            return SidebarTagItem(
                tagId: tagId,
                name: row["name"] ?? "",
                normalizedName: row["normalizedName"] ?? "",
                isProvisional: row["isProvisional"] ?? false,
                usageCount: row["usageCount"] ?? 0,
                unreadCount: unreadCountByTagId[tagId] ?? 0
            )
        }

        let visibleTags = SidebarTagVisibilityPolicy.visibleTags(from: allTagItems)

        return SidebarProjection(
            totalUnread: totalUnread,
            totalStarred: totalStarred,
            starredUnread: starredUnread,
            feedUnreadCounts: feedUnreadCounts,
            tags: visibleTags
        )
    }
}
