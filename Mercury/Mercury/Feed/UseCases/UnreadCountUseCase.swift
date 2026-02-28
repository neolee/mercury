//
//  UnreadCountUseCase.swift
//  Mercury
//

import Foundation
import GRDB

struct UnreadCountUseCase {
    let database: DatabaseManager

    @discardableResult
    func recalculate(forFeedId feedId: Int64) async throws -> Int {
        let count = try await database.read { db in
            try Entry
                .filter(Column("feedId") == feedId)
                .filter(Column("isRead") == false)
                .fetchCount(db)
        }

        try await database.write { db in
            _ = try Feed
                .filter(Column("id") == feedId)
                .updateAll(db, Column("unreadCount").set(to: count))
        }

        return count
    }

    func recalculateAll() async throws {
        try await database.write { db in
            let feedIds = try Feed.fetchAll(db).compactMap(\.id)
            if feedIds.isEmpty {
                return
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT feedId, COUNT(*) AS c
                FROM entry
                WHERE isRead = 0
                GROUP BY feedId
                """
            )

            var countsByFeedId: [Int64: Int] = [:]
            countsByFeedId.reserveCapacity(rows.count)
            for row in rows {
                let id: Int64 = row["feedId"]
                let count: Int = row["c"]
                countsByFeedId[id] = count
            }

            for feedId in feedIds {
                let count = countsByFeedId[feedId] ?? 0
                _ = try Feed
                    .filter(Column("id") == feedId)
                    .updateAll(db, Column("unreadCount").set(to: count))
            }
        }
    }
}
