import Foundation
import GRDB

struct TagBatchStartRequest: Sendable {
    let scopeLabel: String
    let entryIDs: [Int64]
    let skipAlreadyApplied: Bool
    let concurrency: Int
}

enum TagBatchRunEvent: Sendable {
    case started(taskId: UUID, runId: Int64)
    case transitioned(runId: Int64, status: TagBatchRunStatus)
    case progress(runId: Int64, processed: Int, total: Int, succeeded: Int, failed: Int)
    case entryFailed(runId: Int64, entryId: Int64, reason: String)
    case notice(String)
    case terminal(TaskTerminalOutcome)
}

private actor TagBatchRunControlCenter {
    private var stopRequestedTaskIDs: Set<UUID> = []

    func register(taskId: UUID) {
        stopRequestedTaskIDs.remove(taskId)
    }

    func requestStop(taskId: UUID) {
        stopRequestedTaskIDs.insert(taskId)
    }

    func shouldStop(taskId: UUID) -> Bool {
        stopRequestedTaskIDs.contains(taskId)
    }

    func clear(taskId: UUID) {
        stopRequestedTaskIDs.remove(taskId)
    }
}

private actor TagBatchRunCounters {
    private(set) var processed = 0
    private(set) var succeeded = 0
    private(set) var failed = 0

    func markSucceeded() -> (processed: Int, succeeded: Int, failed: Int) {
        processed += 1
        succeeded += 1
        return (processed, succeeded, failed)
    }

    func markFailed() -> (processed: Int, succeeded: Int, failed: Int) {
        processed += 1
        failed += 1
        return (processed, succeeded, failed)
    }
}

private actor TagBatchEntryCursor {
    private let entryIDs: [Int64]
    private var index = 0

    init(entryIDs: [Int64]) {
        self.entryIDs = entryIDs
    }

    func next() -> Int64? {
        guard index < entryIDs.count else { return nil }
        defer { index += 1 }
        return entryIDs[index]
    }
}

private let tagBatchRunControlCenter = TagBatchRunControlCenter()

extension AppModel {
    func startTaggingBatchRun(
        request: TagBatchStartRequest,
        onEvent: @escaping @Sendable (TagBatchRunEvent) async -> Void
    ) async -> UUID {
        let resolvedTaskID = makeTaskID()
        let batchStore = TagBatchStore(db: database)

        do {
            let canStart = try await batchStore.canStartNewRun()
            if canStart == false {
                await onEvent(.notice("Another batch run is active. Finish or discard it before starting a new run."))
                await onEvent(.terminal(.failed(failureReason: .invalidInput, message: "Another batch run is active.")))
                return resolvedTaskID
            }
        } catch {
            await onEvent(.terminal(.failed(failureReason: .storage, message: error.localizedDescription)))
            return resolvedTaskID
        }

        let uniqueRequestedIDs = Array(Set(request.entryIDs)).sorted()
        let selectedCount = uniqueRequestedIDs.count
        let clampedConcurrency = min(max(request.concurrency, 1), 5)

        let runId: Int64
        do {
            runId = try await batchStore.createRun(
                scopeLabel: request.scopeLabel,
                skipAlreadyApplied: request.skipAlreadyApplied,
                concurrency: clampedConcurrency,
                totalSelectedEntries: selectedCount,
                totalPlannedEntries: selectedCount
            )
        } catch {
            await onEvent(.terminal(.failed(failureReason: .storage, message: error.localizedDescription)))
            return resolvedTaskID
        }

        await tagBatchRunControlCenter.register(taskId: resolvedTaskID)
        await onEvent(.started(taskId: resolvedTaskID, runId: runId))

        _ = await enqueueTask(
            taskId: resolvedTaskID,
            kind: .taggingBatch,
            title: "Tagging Batch",
            priority: .userInitiated,
            executionTimeout: nil
        ) { [self, database, credentialStore] executionContext in
            let report = executionContext.reportProgress
            let defaults = loadTaggingAgentDefaults()
            let profile = TaggingLLMRequestProfile(
                templateID: AgentPromptCustomizationConfig.tagging.templateID,
                templateVersion: "v1",
                maxTagCount: BatchTaggingPolicy.maxTagsPerEntry,
                maxNewTagCount: BatchTaggingPolicy.maxNewTagProposalsPerEntry,
                bodyStrategy: .summaryOnly,
                timeoutSeconds: TaskTimeoutPolicy.executionTimeout(for: AppTaskKind.tagging) ?? 60,
                temperatureOverride: nil,
                topPOverride: nil
            )

            do {
                await report(0, "Preparing batch tagging")

                let filteredEntryIDs = try await self.filterBatchTargetEntryIDs(
                    runId: runId,
                    requestedEntryIDs: uniqueRequestedIDs,
                    skipAlreadyApplied: request.skipAlreadyApplied,
                    database: database
                )

                try await batchStore.updateRunPlannedCount(runId: runId, totalPlannedEntries: filteredEntryIDs.count)
                try await batchStore.updateRunStatus(runId: runId, status: .running, startedAt: Date())
                await onEvent(.transitioned(runId: runId, status: .running))

                if filteredEntryIDs.isEmpty {
                    try await batchStore.rebuildReviewRowsFromAssignments(runId: runId)
                    try await batchStore.updateRunStatus(runId: runId, status: .review)
                    await onEvent(.transitioned(runId: runId, status: .review))
                    await onEvent(.terminal(.succeeded))
                    return
                }

                let template = try await loadPromptTemplate(config: .tagging) { notice in
                    await onEvent(.notice(notice))
                }

                let cursor = TagBatchEntryCursor(entryIDs: filteredEntryIDs)
                let counters = TagBatchRunCounters()
                let total = filteredEntryIDs.count
                let workerCount = min(max(clampedConcurrency, 1), max(total, 1))

                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<workerCount {
                        group.addTask {
                            while let entryId = await cursor.next() {
                                if await tagBatchRunControlCenter.shouldStop(taskId: resolvedTaskID) {
                                    break
                                }

                                do {
                                    let success = try await self.processSingleBatchEntry(
                                        runId: runId,
                                        entryId: entryId,
                                        template: template,
                                        defaults: defaults,
                                        profile: profile,
                                        database: database,
                                        credentialStore: credentialStore,
                                        cancellationReasonProvider: executionContext.terminationReason
                                    )

                                    let snapshot: (processed: Int, succeeded: Int, failed: Int)
                                    if success {
                                        snapshot = await counters.markSucceeded()
                                    } else {
                                        snapshot = await counters.markFailed()
                                    }

                                    try await batchStore.updateRunCounters(
                                        runId: runId,
                                        processedEntries: snapshot.processed,
                                        succeededEntries: snapshot.succeeded,
                                        failedEntries: snapshot.failed
                                    )

                                    await report(
                                        Double(snapshot.processed) / Double(max(total, 1)),
                                        "Processed \(snapshot.processed)/\(total)"
                                    )
                                    await onEvent(
                                        .progress(
                                            runId: runId,
                                            processed: snapshot.processed,
                                            total: total,
                                            succeeded: snapshot.succeeded,
                                            failed: snapshot.failed
                                        )
                                    )
                                } catch {
                                    let reason = error.localizedDescription
                                    let now = Date()
                                    try? await batchStore.upsertBatchEntry(
                                        TagBatchEntry(
                                            id: nil,
                                            runId: runId,
                                            entryId: entryId,
                                            lifecycleState: .failed,
                                            attempts: 1,
                                            providerProfileId: nil,
                                            modelProfileId: nil,
                                            promptTokens: nil,
                                            completionTokens: nil,
                                            durationMs: nil,
                                            rawResponse: nil,
                                            errorMessage: reason,
                                            createdAt: now,
                                            updatedAt: now
                                        )
                                    )
                                    let snapshot = await counters.markFailed()
                                    try? await batchStore.updateRunCounters(
                                        runId: runId,
                                        processedEntries: snapshot.processed,
                                        succeededEntries: snapshot.succeeded,
                                        failedEntries: snapshot.failed
                                    )
                                    await onEvent(.entryFailed(runId: runId, entryId: entryId, reason: reason))
                                }
                            }
                        }
                    }
                }

                try await batchStore.rebuildReviewRowsFromAssignments(runId: runId)
                try await batchStore.updateRunStatus(runId: runId, status: .review)
                await onEvent(.transitioned(runId: runId, status: .review))
                await onEvent(.terminal(.succeeded))
            } catch {
                try? await batchStore.updateRunStatus(runId: runId, status: .failed, completedAt: Date())
                await onEvent(.terminal(terminalOutcomeForFailure(error: error, taskKind: .taggingBatch)))
                throw error
            }
        }

        return resolvedTaskID
    }

    func requestCancelTaggingBatchRun(taskId: UUID) async {
        await tagBatchRunControlCenter.requestStop(taskId: taskId)
    }

    func discardTaggingBatchRun(runId: Int64) async throws {
        let batchStore = TagBatchStore(db: database)
        try await batchStore.clearRunStagingData(runId: runId)
        try await batchStore.updateRunStatus(runId: runId, status: .cancelled, completedAt: Date())
    }

    func loadTaggingBatchReviewRows(runId: Int64) async throws -> [TagBatchNewTagReview] {
        try await TagBatchStore(db: database).loadReviewRows(runId: runId)
    }

    func setTaggingBatchReviewDecision(
        runId: Int64,
        normalizedName: String,
        decision: TagBatchReviewDecision
    ) async throws {
        try await TagBatchStore(db: database).updateReviewDecision(
            runId: runId,
            normalizedName: normalizedName,
            decision: decision
        )
    }

    func setTaggingBatchReviewDecisionForAll(
        runId: Int64,
        decision: TagBatchReviewDecision
    ) async throws {
        try await TagBatchStore(db: database).updateAllReviewDecisions(runId: runId, decision: decision)
    }

    func applyTaggingBatchRun(
        runId: Int64,
        onEvent: @escaping @Sendable (TagBatchRunEvent) async -> Void
    ) async throws {
        let batchStore = TagBatchStore(db: database)

        guard let run = try await batchStore.loadRun(id: runId) else {
            throw NSError(
                domain: "Mercury.TagBatch",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Batch run not found."]
            )
        }

        guard run.status == .review || run.status == .applying else {
            throw NSError(
                domain: "Mercury.TagBatch",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Batch run is not in review/applying state."]
            )
        }

        let pendingCount = try await batchStore.countPendingReviews(runId: runId)
        guard pendingCount == 0 else {
            throw NSError(
                domain: "Mercury.TagBatch",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Resolve all review decisions before apply."]
            )
        }

        try await batchStore.updateRunStatus(runId: runId, status: .applying)
        await onEvent(.transitioned(runId: runId, status: .applying))

        let allEntryIDs = try await loadBatchEntryIDsForApply(runId: runId, database: database)
        let chunks = chunked(allEntryIDs, size: BatchTaggingPolicy.applyChunkSize)
        let totalChunks = chunks.count
        var checkpoint = try await batchStore.loadCheckpoint(runId: runId)
        let startChunkIndex = max(checkpoint?.lastAppliedChunkIndex ?? -1, -1) + 1

        var insertedEntryTagCount = run.insertedEntryTagCount
        var createdTagCount = run.createdTagCount

        if totalChunks > 0 {
            for chunkIndex in startChunkIndex..<totalChunks {
                let entryIDs = chunks[chunkIndex]
                let assignments = try await batchStore.loadAssignments(runId: runId, entryIds: entryIDs)
                let decisions = try await loadReviewDecisionMap(runId: runId, database: database)
                let stats = try await applyBatchChunk(
                    runId: runId,
                    entryIDs: entryIDs,
                    assignments: assignments,
                    reviewDecisions: decisions,
                    database: database
                )

                insertedEntryTagCount += stats.insertedEntryTagCount
                createdTagCount += stats.createdTagCount

                checkpoint = TagBatchApplyCheckpoint(
                    id: checkpoint?.id,
                    runId: runId,
                    lastAppliedChunkIndex: chunkIndex,
                    totalChunks: totalChunks,
                    lastAppliedEntryId: entryIDs.last,
                    updatedAt: Date()
                )
                if let checkpoint {
                    try await batchStore.saveCheckpoint(checkpoint)
                }

                let processedEntries = min((chunkIndex + 1) * BatchTaggingPolicy.applyChunkSize, allEntryIDs.count)
                await onEvent(
                    .progress(
                        runId: runId,
                        processed: processedEntries,
                        total: allEntryIDs.count,
                        succeeded: run.succeededEntries,
                        failed: run.failedEntries
                    )
                )
            }
        }

        try await reconcileTagUsageAndProvisionalState(database: database)

        let reviewRows = try await batchStore.loadReviewRows(runId: runId)
        let keptProposalCount = reviewRows.filter { $0.decision == .keep }.count
        let discardedProposalCount = reviewRows.filter { $0.decision == .discard }.count

        try await batchStore.finalizeRunAfterApply(
            runId: runId,
            keptProposalCount: keptProposalCount,
            discardedProposalCount: discardedProposalCount,
            insertedEntryTagCount: insertedEntryTagCount,
            createdTagCount: createdTagCount
        )
        try await batchStore.clearRunStagingData(runId: runId)

        await onEvent(.transitioned(runId: runId, status: .done))
        await onEvent(.terminal(.succeeded))
    }
}

private extension AppModel {
    struct TagBatchApplyChunkStats {
        let insertedEntryTagCount: Int
        let createdTagCount: Int
    }

    func loadBatchEntryIDsForApply(
        runId: Int64,
        database: DatabaseManager
    ) async throws -> [Int64] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT entryId
                FROM tag_batch_entry
                WHERE runId = ?
                  AND lifecycleState IN (?, ?)
                ORDER BY entryId ASC
                """,
                arguments: [
                    runId,
                    TagBatchEntryLifecycleState.stagedReady.rawValue,
                    TagBatchEntryLifecycleState.applied.rawValue
                ]
            )
            return rows.compactMap { row -> Int64? in row["entryId"] }
        }
    }

    func loadReviewDecisionMap(
        runId: Int64,
        database: DatabaseManager
    ) async throws -> [String: TagBatchReviewDecision] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT normalizedName, decision FROM tag_batch_new_tag_review WHERE runId = ?",
                arguments: [runId]
            )
            var result: [String: TagBatchReviewDecision] = [:]
            for row in rows {
                guard let normalizedName: String = row["normalizedName"],
                      let decisionRaw: String = row["decision"],
                      let decision = TagBatchReviewDecision(rawValue: decisionRaw) else {
                    continue
                }
                result[normalizedName] = decision
            }
            return result
        }
    }

    func applyBatchChunk(
        runId: Int64,
        entryIDs: [Int64],
        assignments: [TagBatchAssignmentStaging],
        reviewDecisions: [String: TagBatchReviewDecision],
        database: DatabaseManager
    ) async throws -> TagBatchApplyChunkStats {
        try await database.write { db in
            var insertedEntryTagCount = 0
            var createdTagCount = 0

            for assignment in assignments {
                guard let tagId = try self.resolveBatchAssignmentTagId(
                    assignment: assignment,
                    reviewDecisions: reviewDecisions,
                    database: db,
                    createdTagCount: &createdTagCount
                ) else {
                    continue
                }

                try db.execute(
                    sql: """
                    INSERT INTO entry_tag (entryId, tagId, source, confidence)
                    VALUES (?, ?, ?, NULL)
                    ON CONFLICT(entryId, tagId) DO NOTHING
                    """,
                    arguments: [assignment.entryId, tagId, "ai_batch"]
                )
                if db.changesCount > 0 {
                    insertedEntryTagCount += 1
                }
            }

            if entryIDs.isEmpty == false {
                let updatedAt = Date()
                for entryId in entryIDs {
                    try db.execute(
                        sql: """
                        UPDATE tag_batch_entry
                        SET lifecycleState = ?, updatedAt = ?
                        WHERE runId = ?
                          AND entryId = ?
                        """,
                        arguments: [
                            TagBatchEntryLifecycleState.applied.rawValue,
                            updatedAt,
                            runId,
                            entryId
                        ]
                    )
                }
            }

            return TagBatchApplyChunkStats(
                insertedEntryTagCount: insertedEntryTagCount,
                createdTagCount: createdTagCount
            )
        }
    }

    func resolveBatchAssignmentTagId(
        assignment: TagBatchAssignmentStaging,
        reviewDecisions: [String: TagBatchReviewDecision],
        database: Database,
        createdTagCount: inout Int
    ) throws -> Int64? {
        if let existingTagId = try resolveTagIdByNormalizedName(
            normalizedName: assignment.normalizedName,
            database: database
        ) {
            return existingTagId
        }

        guard assignment.assignmentKind == .newProposal else {
            return nil
        }

        let decision = reviewDecisions[assignment.normalizedName] ?? .pending
        guard decision == .keep else {
            return nil
        }

        var createdTag = Tag(
            id: nil,
            name: assignment.displayName,
            normalizedName: assignment.normalizedName,
            isProvisional: true,
            usageCount: 0
        )

        do {
            try createdTag.insert(database)
            createdTagCount += 1
            return createdTag.id
        } catch {
            // Another path may have inserted the same normalized name during apply.
            return try resolveTagIdByNormalizedName(
                normalizedName: assignment.normalizedName,
                database: database
            )
        }
    }

    func resolveTagIdByNormalizedName(
        normalizedName: String,
        database: Database
    ) throws -> Int64? {
        if let directTagId = try Int64.fetchOne(
            database,
            sql: "SELECT id FROM tag WHERE normalizedName = ? LIMIT 1",
            arguments: [normalizedName]
        ) {
            return directTagId
        }

        return try Int64.fetchOne(
            database,
            sql: """
            SELECT t.id
            FROM tag_alias a
            JOIN tag t ON t.id = a.tagId
            WHERE a.normalizedAlias = ?
            LIMIT 1
            """,
            arguments: [normalizedName]
        )
    }

    func reconcileTagUsageAndProvisionalState(database: DatabaseManager) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE tag
                SET usageCount = (
                    SELECT COUNT(*)
                    FROM entry_tag
                    WHERE entry_tag.tagId = tag.id
                )
                """
            )
            try db.execute(
                sql: "UPDATE tag SET isProvisional = 1 WHERE usageCount < ?",
                arguments: [TaggingPolicy.provisionalPromotionThreshold]
            )
            try db.execute(
                sql: "UPDATE tag SET isProvisional = 0 WHERE usageCount >= ?",
                arguments: [TaggingPolicy.provisionalPromotionThreshold]
            )
        }
    }

    func chunked(_ values: [Int64], size: Int) -> [[Int64]] {
        guard size > 0, values.isEmpty == false else { return values.isEmpty ? [] : [values] }
        var chunks: [[Int64]] = []
        chunks.reserveCapacity((values.count + size - 1) / size)
        var index = 0
        while index < values.count {
            let end = min(index + size, values.count)
            chunks.append(Array(values[index..<end]))
            index = end
        }
        return chunks
    }

    func filterBatchTargetEntryIDs(
        runId: Int64,
        requestedEntryIDs: [Int64],
        skipAlreadyApplied: Bool,
        database: DatabaseManager
    ) async throws -> [Int64] {
        guard skipAlreadyApplied else {
            return Array(requestedEntryIDs.prefix(BatchTaggingPolicy.absoluteSafetyCap))
        }

        let filtered = try await database.read { db -> [Int64] in
            var result: [Int64] = []
            result.reserveCapacity(requestedEntryIDs.count)

            for entryId in requestedEntryIDs {
                let alreadyApplied = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM tag_batch_entry
                        WHERE entryId = ?
                          AND lifecycleState = ?
                        LIMIT 1
                    )
                    """,
                    arguments: [entryId, TagBatchEntryLifecycleState.applied.rawValue]
                ) ?? false
                if alreadyApplied == false {
                    result.append(entryId)
                }
            }
            return result
        }

        return Array(filtered.prefix(BatchTaggingPolicy.absoluteSafetyCap))
    }

    func processSingleBatchEntry(
        runId: Int64,
        entryId: Int64,
        template: AgentPromptTemplate,
        defaults: TaggingAgentDefaults,
        profile: TaggingLLMRequestProfile,
        database: DatabaseManager,
        credentialStore: CredentialStore,
        cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider
    ) async throws -> Bool {
        let batchStore = TagBatchStore(db: database)
        let now = Date()

        try await batchStore.upsertBatchEntry(
            TagBatchEntry(
                id: nil,
                runId: runId,
                entryId: entryId,
                lifecycleState: .running,
                attempts: 1,
                providerProfileId: nil,
                modelProfileId: nil,
                promptTokens: nil,
                completionTokens: nil,
                durationMs: nil,
                rawResponse: nil,
                errorMessage: nil,
                createdAt: now,
                updatedAt: now
            )
        )

        guard let source = try await loadTaggingBatchSource(entryId: entryId, database: database) else {
            try await batchStore.upsertBatchEntry(
                TagBatchEntry(
                    id: nil,
                    runId: runId,
                    entryId: entryId,
                    lifecycleState: .failed,
                    attempts: 1,
                    providerProfileId: nil,
                    modelProfileId: nil,
                    promptTokens: nil,
                    completionTokens: nil,
                    durationMs: nil,
                    rawResponse: nil,
                    errorMessage: "Entry missing or has no usable title/summary.",
                    createdAt: now,
                    updatedAt: Date()
                )
            )
            return false
        }

        let executionResult = try await executeWithRateLimitRetry(
            entryId: entryId,
            title: source.title,
            body: source.summary,
            template: template,
            profile: profile,
            defaults: defaults,
            database: database,
            credentialStore: credentialStore,
            cancellationReasonProvider: cancellationReasonProvider
        )

        let finalizedAt = Date()
        try await batchStore.upsertBatchEntry(
            TagBatchEntry(
                id: nil,
                runId: runId,
                entryId: entryId,
                lifecycleState: .stagedReady,
                attempts: 1,
                providerProfileId: executionResult.providerProfileId,
                modelProfileId: executionResult.modelProfileId,
                promptTokens: executionResult.promptTokens,
                completionTokens: executionResult.completionTokens,
                durationMs: executionResult.durationMs,
                rawResponse: executionResult.rawResponse,
                errorMessage: nil,
                createdAt: now,
                updatedAt: finalizedAt
            )
        )

        for item in executionResult.resolvedItems {
            let kind: TagBatchAssignmentKind = item.resolvedTagID == nil ? .newProposal : .matched
            try await batchStore.upsertAssignment(
                TagBatchAssignmentStaging(
                    id: nil,
                    runId: runId,
                    entryId: entryId,
                    normalizedName: item.normalizedName,
                    displayName: item.displayName,
                    resolvedTagId: item.resolvedTagID,
                    assignmentKind: kind,
                    createdAt: now,
                    updatedAt: finalizedAt
                )
            )
        }

        return true
    }

    func executeWithRateLimitRetry(
        entryId: Int64,
        title: String,
        body: String,
        template: AgentPromptTemplate,
        profile: TaggingLLMRequestProfile,
        defaults: TaggingAgentDefaults,
        database: DatabaseManager,
        credentialStore: CredentialStore,
        cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider
    ) async throws -> TaggingPerEntryResult {
        var attempt = 0
        var lastError: Error?

        while attempt <= BatchTaggingPolicy.maxRateLimitRetries {
            do {
                return try await executeTaggingPerEntry(
                    entryId: entryId,
                    title: title,
                    body: body,
                    template: template,
                    profile: profile,
                    defaults: defaults,
                    taskKind: .taggingBatch,
                    database: database,
                    credentialStore: credentialStore,
                    cancellationReasonProvider: cancellationReasonProvider
                )
            } catch {
                if isCancellationLikeError(error) {
                    throw error
                }

                lastError = error
                guard isRateLimitError(error), attempt < BatchTaggingPolicy.maxRateLimitRetries else {
                    throw error
                }

                let delay = min(
                    BatchTaggingPolicy.retryBaseDelaySeconds * pow(2.0, Double(attempt)),
                    BatchTaggingPolicy.retryMaxDelaySeconds
                )
                try await Task.sleep(for: .seconds(delay))
                attempt += 1
            }
        }

        throw lastError ?? TaggingExecutionError.noUsableModelRoute
    }

    func loadTaggingBatchSource(
        entryId: Int64,
        database: DatabaseManager
    ) async throws -> (title: String, summary: String)? {
        try await database.read { db in
            guard let entry = try Entry
                .filter(Column("id") == entryId)
                .fetchOne(db) else {
                return nil
            }

            let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let effectiveTitle = title.isEmpty ? "Untitled" : title
            let effectiveSummary = summary.isEmpty ? effectiveTitle : summary
            if effectiveSummary.isEmpty {
                return nil
            }
            return (effectiveTitle, effectiveSummary)
        }
    }
}
