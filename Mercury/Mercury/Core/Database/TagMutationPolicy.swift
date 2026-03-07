//
//  TagMutationPolicy.swift
//  Mercury
//

import Foundation
import GRDB

enum TagMutationPolicy {
    static func assertNoActiveBatchLifecycle(_ db: Database) throws {
        let hasActiveBatchRun = try TagBatchRun
            .filter(TagBatchRunStatus.activeLifecycleRawValues.contains(Column("status")))
            .fetchCount(db) > 0
        if hasActiveBatchRun {
            throw TagMutationError.batchRunActive
        }
    }

    static func deleteTagRows(id: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM entry_tag WHERE tagId = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM tag_alias WHERE tagId = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id])
    }
}
