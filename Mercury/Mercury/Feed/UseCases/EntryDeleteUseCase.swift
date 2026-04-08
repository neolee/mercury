//
//  EntryDeleteUseCase.swift
//  Mercury
//

import Foundation
import GRDB

enum EntryDeleteError: LocalizedError, Equatable {
    case blockedByActiveTagBatch

    var errorDescription: String? {
        switch self {
        case .blockedByActiveTagBatch:
            return "This entry is part of an active batch tagging run. Finish or discard the batch before deleting it."
        }
    }
}

struct EntryDeleteUseCase {
    let database: DatabaseManager

    @discardableResult
    func deleteEntry(entryId: Int64) async throws -> Bool {
        try await database.write { db in
            guard let entry = try Entry.fetchOne(db, key: entryId), entry.isDeleted == false else {
                return false
            }

            if try isBlockedByActiveTagBatch(entryId: entryId, db: db) {
                throw EntryDeleteError.blockedByActiveTagBatch
            }

            let affectedTagIDs = try Int64.fetchAll(
                db,
                EntryTag
                    .select(Column("tagId"))
                    .filter(Column("entryId") == entryId)
                    .distinct()
            )

            _ = try Content
                .filter(Column("entryId") == entryId)
                .deleteAll(db)
            _ = try ContentHTMLCache
                .filter(Column("entryId") == entryId)
                .deleteAll(db)
            _ = try EntryNote
                .filter(Column("entryId") == entryId)
                .deleteAll(db)
            _ = try TagBatchAssignmentStaging
                .filter(Column("entryId") == entryId)
                .deleteAll(db)
            _ = try TagBatchEntry
                .filter(Column("entryId") == entryId)
                .deleteAll(db)
            _ = try EntryTag
                .filter(Column("entryId") == entryId)
                .deleteAll(db)
            _ = try AgentTaskRun
                .filter(Column("entryId") == entryId)
                .deleteAll(db)

            try refreshTagUsageCounts(for: affectedTagIDs, db: db)

            let updatedRowCount = try Entry
                .filter(Column("id") == entryId)
                .filter(Column("isDeleted") == false)
                .updateAll(db, Column("isDeleted").set(to: true))
            return updatedRowCount > 0
        }
    }

    private func isBlockedByActiveTagBatch(entryId: Int64, db: Database) throws -> Bool {
        try TagBatchEntry
            .joining(
                required: TagBatchEntry.run.filter(
                    TagBatchRunStatus.activeLifecycleRawValues.contains(Column("status"))
                )
            )
            .filter(Column("entryId") == entryId)
            .fetchCount(db) > 0
    }

    private func refreshTagUsageCounts(for tagIDs: [Int64], db: Database) throws {
        for tagID in Set(tagIDs) {
            try db.execute(
                sql: """
                UPDATE tag
                SET usageCount = (
                    SELECT COUNT(*)
                    FROM entry_tag
                    WHERE tagId = ?
                )
                WHERE id = ?
                """,
                arguments: [tagID, tagID]
            )
            try db.execute(
                sql: """
                UPDATE tag
                SET isProvisional = CASE
                    WHEN usageCount >= ? THEN 0
                    ELSE 1
                END
                WHERE id = ?
                """,
                arguments: [TaggingPolicy.provisionalPromotionThreshold, tagID]
            )
        }
    }
}
