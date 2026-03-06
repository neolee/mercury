import Foundation
import GRDB

final class TagBatchStore {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func createRun(
        scopeLabel: String,
        skipAlreadyApplied: Bool,
        skipAlreadyTagged: Bool,
        concurrency: Int,
        totalSelectedEntries: Int,
        totalPlannedEntries: Int
    ) async throws -> Int64 {
        let now = Date()
        return try await db.write { db in
            var run = TagBatchRun(
                id: nil,
                status: .configure,
                scopeLabel: scopeLabel,
                skipAlreadyApplied: skipAlreadyApplied,
                skipAlreadyTagged: skipAlreadyTagged,
                concurrency: concurrency,
                totalSelectedEntries: totalSelectedEntries,
                totalPlannedEntries: totalPlannedEntries,
                processedEntries: 0,
                succeededEntries: 0,
                failedEntries: 0,
                keptProposalCount: 0,
                discardedProposalCount: 0,
                insertedEntryTagCount: 0,
                createdTagCount: 0,
                startedAt: nil,
                completedAt: nil,
                createdAt: now,
                updatedAt: now
            )
            try run.insert(db)
            guard let runID = run.id else {
                throw NSError(
                    domain: "Mercury.TagBatchStore",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing tag batch run id"]
                )
            }
            return runID
        }
    }

    func canStartNewRun() async throws -> Bool {
        try await db.read { db in
            let activeStatuses = [
                TagBatchRunStatus.running.rawValue,
                TagBatchRunStatus.readyNext.rawValue,
                TagBatchRunStatus.review.rawValue,
                TagBatchRunStatus.applying.rawValue
            ]
            let placeholders = activeStatuses.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT EXISTS(SELECT 1 FROM tag_batch_run WHERE status IN (\(placeholders)))"
            let exists = try Bool.fetchOne(db, sql: sql, arguments: StatementArguments(activeStatuses)) ?? false
            return !exists
        }
    }

    func loadLatestRun() async throws -> TagBatchRun? {
        try await db.read { db in
            try TagBatchRun
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    func loadActiveRun() async throws -> TagBatchRun? {
        try await db.read { db in
            try TagBatchRun
                .filter(
                    Column("status") == TagBatchRunStatus.running.rawValue
                    || Column("status") == TagBatchRunStatus.readyNext.rawValue
                    || Column("status") == TagBatchRunStatus.review.rawValue
                    || Column("status") == TagBatchRunStatus.applying.rawValue
                )
                .order(Column("updatedAt").desc)
                .fetchOne(db)
        }
    }

    func loadRun(id: Int64) async throws -> TagBatchRun? {
        try await db.read { db in
            try TagBatchRun
                .filter(Column("id") == id)
                .fetchOne(db)
        }
    }

    func updateRunStatus(
        runId: Int64,
        status: TagBatchRunStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) async throws {
        let now = Date()
        try await db.write { db in
            var assignments: [ColumnAssignment] = [
                Column("status").set(to: status.rawValue),
                Column("updatedAt").set(to: now)
            ]
            if let startedAt {
                assignments.append(Column("startedAt").set(to: startedAt))
            }
            if let completedAt {
                assignments.append(Column("completedAt").set(to: completedAt))
            }

            _ = try TagBatchRun
                .filter(Column("id") == runId)
                .updateAll(db, assignments)
        }
    }

    func updateRunCounters(
        runId: Int64,
        processedEntries: Int,
        succeededEntries: Int,
        failedEntries: Int
    ) async throws {
        let now = Date()
        try await db.write { db in
            _ = try TagBatchRun
                .filter(Column("id") == runId)
                .updateAll(
                    db,
                    [
                        Column("processedEntries").set(to: processedEntries),
                        Column("succeededEntries").set(to: succeededEntries),
                        Column("failedEntries").set(to: failedEntries),
                        Column("updatedAt").set(to: now)
                    ]
                )
        }
    }

    func updateRunPlannedCount(runId: Int64, totalPlannedEntries: Int) async throws {
        let now = Date()
        try await db.write { db in
            _ = try TagBatchRun
                .filter(Column("id") == runId)
                .updateAll(
                    db,
                    [
                        Column("totalPlannedEntries").set(to: totalPlannedEntries),
                        Column("updatedAt").set(to: now)
                    ]
                )
        }
    }

    func upsertBatchEntry(_ entry: TagBatchEntry) async throws {
        let sql = """
        INSERT INTO tag_batch_entry (
            runId, entryId, lifecycleState, attempts, providerProfileId, modelProfileId,
            promptTokens, completionTokens, durationMs, rawResponse, errorMessage, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(runId, entryId) DO UPDATE SET
            lifecycleState = excluded.lifecycleState,
            attempts = excluded.attempts,
            providerProfileId = excluded.providerProfileId,
            modelProfileId = excluded.modelProfileId,
            promptTokens = excluded.promptTokens,
            completionTokens = excluded.completionTokens,
            durationMs = excluded.durationMs,
            rawResponse = excluded.rawResponse,
            errorMessage = excluded.errorMessage,
            updatedAt = excluded.updatedAt
        """

        try await db.write { db in
            try db.execute(
                sql: sql,
                arguments: [
                    entry.runId,
                    entry.entryId,
                    entry.lifecycleState.rawValue,
                    entry.attempts,
                    entry.providerProfileId,
                    entry.modelProfileId,
                    entry.promptTokens,
                    entry.completionTokens,
                    entry.durationMs,
                    entry.rawResponse,
                    entry.errorMessage,
                    entry.createdAt,
                    entry.updatedAt
                ]
            )
        }
    }

    func upsertAssignment(_ assignment: TagBatchAssignmentStaging) async throws {
        let sql = """
        INSERT INTO tag_batch_assignment_staging (
            runId, entryId, normalizedName, displayName, resolvedTagId, assignmentKind, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(runId, entryId, normalizedName) DO UPDATE SET
            displayName = excluded.displayName,
            resolvedTagId = excluded.resolvedTagId,
            assignmentKind = excluded.assignmentKind,
            updatedAt = excluded.updatedAt
        """

        try await db.write { db in
            try db.execute(
                sql: sql,
                arguments: [
                    assignment.runId,
                    assignment.entryId,
                    assignment.normalizedName,
                    assignment.displayName,
                    assignment.resolvedTagId,
                    assignment.assignmentKind.rawValue,
                    assignment.createdAt,
                    assignment.updatedAt
                ]
            )
        }
    }

    func upsertReview(_ review: TagBatchNewTagReview) async throws {
        let sql = """
        INSERT INTO tag_batch_new_tag_review (
            runId, normalizedName, displayName, hitCount, sampleEntryCount, decision, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(runId, normalizedName) DO UPDATE SET
            displayName = excluded.displayName,
            hitCount = excluded.hitCount,
            sampleEntryCount = excluded.sampleEntryCount,
            decision = excluded.decision,
            updatedAt = excluded.updatedAt
        """

        try await db.write { db in
            try db.execute(
                sql: sql,
                arguments: [
                    review.runId,
                    review.normalizedName,
                    review.displayName,
                    review.hitCount,
                    review.sampleEntryCount,
                    review.decision.rawValue,
                    review.createdAt,
                    review.updatedAt
                ]
            )
        }
    }

    func loadReviewRows(runId: Int64) async throws -> [TagBatchNewTagReview] {
        try await db.read { db in
            try TagBatchNewTagReview
                .filter(Column("runId") == runId)
                .order(Column("hitCount").desc)
                .order(Column("displayName").asc)
                .fetchAll(db)
        }
    }

    func updateReviewDecision(
        runId: Int64,
        normalizedName: String,
        decision: TagBatchReviewDecision
    ) async throws {
        let now = Date()
        try await db.write { db in
            _ = try TagBatchNewTagReview
                .filter(Column("runId") == runId && Column("normalizedName") == normalizedName)
                .updateAll(
                    db,
                    [
                        Column("decision").set(to: decision.rawValue),
                        Column("updatedAt").set(to: now)
                    ]
                )
        }
    }

    func updateAllReviewDecisions(
        runId: Int64,
        decision: TagBatchReviewDecision
    ) async throws {
        let now = Date()
        try await db.write { db in
            _ = try TagBatchNewTagReview
                .filter(Column("runId") == runId)
                .updateAll(
                    db,
                    [
                        Column("decision").set(to: decision.rawValue),
                        Column("updatedAt").set(to: now)
                    ]
                )
        }
    }

    func countPendingReviews(runId: Int64) async throws -> Int {
        try await db.read { db in
            try TagBatchNewTagReview
                .filter(Column("runId") == runId && Column("decision") == TagBatchReviewDecision.pending.rawValue)
                .fetchCount(db)
        }
    }

    func loadRunSuggestionStats(runId: Int64) async throws -> (totalSuggestedTags: Int, newTagCount: Int) {
        try await db.read { db in
            let totalSuggested = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM tag_batch_assignment_staging WHERE runId = ?",
                arguments: [runId]
            ) ?? 0

            let newTagCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM tag_batch_new_tag_review WHERE runId = ?",
                arguments: [runId]
            ) ?? 0

            return (totalSuggested, newTagCount)
        }
    }

    func loadAssignments(runId: Int64) async throws -> [TagBatchAssignmentStaging] {
        try await db.read { db in
            try TagBatchAssignmentStaging
                .filter(Column("runId") == runId)
                .fetchAll(db)
        }
    }

    func loadAssignments(runId: Int64, entryIds: [Int64]) async throws -> [TagBatchAssignmentStaging] {
        guard entryIds.isEmpty == false else { return [] }
        return try await db.read { db in
            try TagBatchAssignmentStaging
                .filter(Column("runId") == runId)
                .filter(entryIds.contains(Column("entryId")))
                .fetchAll(db)
        }
    }

    func rebuildReviewRowsFromAssignments(runId: Int64) async throws {
        try await db.write { db in
            try db.execute(
                sql: "DELETE FROM tag_batch_new_tag_review WHERE runId = ?",
                arguments: [runId]
            )

            let now = Date()
            try db.execute(
                sql: """
                INSERT INTO tag_batch_new_tag_review (
                    runId,
                    normalizedName,
                    displayName,
                    hitCount,
                    sampleEntryCount,
                    decision,
                    createdAt,
                    updatedAt
                )
                SELECT
                    runId,
                    normalizedName,
                    displayName,
                    COUNT(*) AS hitCount,
                    COUNT(DISTINCT entryId) AS sampleEntryCount,
                    ?,
                    ?,
                    ?
                FROM tag_batch_assignment_staging
                WHERE runId = ?
                  AND assignmentKind = ?
                GROUP BY runId, normalizedName, displayName
                """,
                arguments: [
                    TagBatchReviewDecision.pending.rawValue,
                    now,
                    now,
                    runId,
                    TagBatchAssignmentKind.newProposal.rawValue
                ]
            )
        }
    }

    func saveCheckpoint(_ checkpoint: TagBatchApplyCheckpoint) async throws {
        let sql = """
        INSERT INTO tag_batch_apply_checkpoint (
            runId, lastAppliedChunkIndex, totalChunks, lastAppliedEntryId, updatedAt
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(runId) DO UPDATE SET
            lastAppliedChunkIndex = excluded.lastAppliedChunkIndex,
            totalChunks = excluded.totalChunks,
            lastAppliedEntryId = excluded.lastAppliedEntryId,
            updatedAt = excluded.updatedAt
        """

        try await db.write { db in
            try db.execute(
                sql: sql,
                arguments: [
                    checkpoint.runId,
                    checkpoint.lastAppliedChunkIndex,
                    checkpoint.totalChunks,
                    checkpoint.lastAppliedEntryId,
                    checkpoint.updatedAt
                ]
            )
        }
    }

    func loadCheckpoint(runId: Int64) async throws -> TagBatchApplyCheckpoint? {
        try await db.read { db in
            try TagBatchApplyCheckpoint
                .filter(Column("runId") == runId)
                .fetchOne(db)
        }
    }

    func finalizeRunAfterApply(
        runId: Int64,
        keptProposalCount: Int,
        discardedProposalCount: Int,
        insertedEntryTagCount: Int,
        createdTagCount: Int
    ) async throws {
        let now = Date()
        try await db.write { db in
            _ = try TagBatchRun
                .filter(Column("id") == runId)
                .updateAll(
                    db,
                    [
                        Column("status").set(to: TagBatchRunStatus.done.rawValue),
                        Column("keptProposalCount").set(to: keptProposalCount),
                        Column("discardedProposalCount").set(to: discardedProposalCount),
                        Column("insertedEntryTagCount").set(to: insertedEntryTagCount),
                        Column("createdTagCount").set(to: createdTagCount),
                        Column("completedAt").set(to: now),
                        Column("updatedAt").set(to: now)
                    ]
                )
        }
    }

    func clearRunStagingData(runId: Int64, preserveAppliedEntries: Bool = false) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM tag_batch_assignment_staging WHERE runId = ?", arguments: [runId])
            try db.execute(sql: "DELETE FROM tag_batch_new_tag_review WHERE runId = ?", arguments: [runId])
            if preserveAppliedEntries {
                // Keep applied rows intact for future analysis/debugging and skipAlreadyApplied filtering.
                try db.execute(
                    sql: "DELETE FROM tag_batch_entry WHERE runId = ? AND lifecycleState <> ?",
                    arguments: [runId, TagBatchEntryLifecycleState.applied.rawValue]
                )
            } else {
                try db.execute(sql: "DELETE FROM tag_batch_entry WHERE runId = ?", arguments: [runId])
            }
            try db.execute(sql: "DELETE FROM tag_batch_apply_checkpoint WHERE runId = ?", arguments: [runId])
        }
    }

    func trimCompletedRunHistory(keepLast count: Int) async throws {
        guard count >= 0 else { return }
        let completedStatuses = [TagBatchRunStatus.done.rawValue, TagBatchRunStatus.cancelled.rawValue]
        let placeholders = completedStatuses.map { _ in "?" }.joined(separator: ",")

        let sql = """
        DELETE FROM tag_batch_run
        WHERE id IN (
            SELECT id
            FROM tag_batch_run
            WHERE status IN (\(placeholders))
            ORDER BY createdAt DESC
            LIMIT -1 OFFSET ?
        )
        """

        try await db.write { db in
            var args = StatementArguments(completedStatuses)
            args += [count]
            try db.execute(sql: sql, arguments: args)
        }
    }
}
