import Foundation
import GRDB

enum TranslationStorageError: LocalizedError {
    case targetLanguageRequired
    case outputLanguageRequired
    case sourceContentHashRequired
    case segmenterVersionRequired
    case segmentsRequired
    case missingTaskRunID
    case missingTranslatedSegment(sourceSegmentId: String)
    case checkpointRunNotFound(taskRunId: Int64)
    case checkpointRunNotRunning(taskRunId: Int64)

    var errorDescription: String? {
        switch self {
        case .targetLanguageRequired:
            return "Target language is required."
        case .outputLanguageRequired:
            return "Output language is required."
        case .sourceContentHashRequired:
            return "Source content hash is required."
        case .segmenterVersionRequired:
            return "Segmenter version is required."
        case .segmentsRequired:
            return "At least one translated segment is required."
        case .missingTaskRunID:
            return "Task run ID is missing after insert."
        case .missingTranslatedSegment(let sourceSegmentId):
            return "Missing translated segment for source segment id \(sourceSegmentId)."
        case .checkpointRunNotFound(let taskRunId):
            return "Checkpoint run \(taskRunId) was not found."
        case .checkpointRunNotRunning(let taskRunId):
            return "Checkpoint run \(taskRunId) is not in running state."
        }
    }
}

struct TranslationStoredRecord: Sendable {
    let run: AgentTaskRun
    let result: TranslationResult
    let segments: [TranslationSegment]
    let isCheckpointRunning: Bool
    let isCheckpointOrphaned: Bool
}

struct TranslationPersistedSegmentInput: Sendable {
    let sourceSegmentId: String
    let orderIndex: Int
    let sourceTextSnapshot: String?
    let translatedText: String
}

enum TranslationStorageQueryHelper {
    static func normalizeTargetLanguage(_ targetLanguage: String) -> String {
        AgentLanguageOption.normalizeCode(targetLanguage)
    }

    static func makeSlotKey(
        entryId: Int64,
        targetLanguage: String
    ) -> TranslationSlotKey {
        TranslationSlotKey(
            entryId: entryId,
            targetLanguage: normalizeTargetLanguage(targetLanguage)
        )
    }
}

extension AppModel {
    func makeTranslationSlotKey(
        entryId: Int64,
        targetLanguage: String
    ) -> TranslationSlotKey {
        TranslationStorageQueryHelper.makeSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage
        )
    }

    func loadTranslationRecord(slotKey: TranslationSlotKey) async throws -> TranslationStoredRecord? {
        let normalizedLanguage = TranslationStorageQueryHelper.normalizeTargetLanguage(slotKey.targetLanguage)

        return try await database.read { db in
            guard let result = try TranslationResult
                .filter(Column("entryId") == slotKey.entryId)
                .filter(Column("targetLanguage") == normalizedLanguage)
                .order(Column("updatedAt").desc)
                .order(Column("createdAt").desc)
                .fetchOne(db) else {
                return nil
            }

            guard let run = try AgentTaskRun
                .filter(Column("id") == result.taskRunId)
                .fetchOne(db) else {
                return nil
            }

            let segments = try TranslationSegment
                .filter(Column("taskRunId") == result.taskRunId)
                .order(Column("orderIndex").asc)
                .fetchAll(db)

            let isCheckpointRunning = result.runStatus == .running
            return TranslationStoredRecord(
                run: run,
                result: result,
                segments: segments,
                isCheckpointRunning: isCheckpointRunning,
                isCheckpointOrphaned: isCheckpointRunning && run.status != .running
            )
        }
    }

    @discardableResult
    func deleteTranslationRecord(slotKey: TranslationSlotKey) async throws -> Bool {
        try await clearTranslationRecords(
            entryId: slotKey.entryId,
            targetLanguage: slotKey.targetLanguage
        ) > 0
    }

    @discardableResult
    func clearTranslationRecords(entryId: Int64, targetLanguage: String) async throws -> Int {
        let normalizedLanguage = TranslationStorageQueryHelper.normalizeTargetLanguage(targetLanguage)

        return try await database.write { db in
            let runIDs = try Int64.fetchAll(
                db,
                TranslationResult
                    .select(Column("taskRunId"))
                    .filter(Column("entryId") == entryId)
                    .filter(Column("targetLanguage") == normalizedLanguage)
            )
            return try deleteTranslationRunIDs(runIDs, in: db)
        }
    }

    func translationSourceSegments(entryId: Int64) async throws -> ReaderSourceSegmentsSnapshot? {
        guard let markdown = try await summarySourceMarkdown(entryId: entryId) else {
            return nil
        }
        return try TranslationSegmentExtractor.extract(entryId: entryId, markdown: markdown)
    }

    @discardableResult
    func startTranslationRunForCheckpoint(
        entryId: Int64,
        agentProfileId: Int64?,
        providerProfileId: Int64?,
        modelProfileId: Int64?,
        promptVersion: String?,
        targetLanguage: String,
        sourceContentHash: String,
        segmenterVersion: String,
        outputLanguage: String,
        templateId: String?,
        templateVersion: String?,
        runtimeParameterSnapshot: [String: String],
        durationMs: Int?
    ) async throws -> Int64 {
        let normalizedTargetLanguage = TranslationStorageQueryHelper.normalizeTargetLanguage(targetLanguage)
        guard normalizedTargetLanguage.isEmpty == false else {
            throw TranslationStorageError.targetLanguageRequired
        }

        let normalizedOutputLanguage = TranslationStorageQueryHelper.normalizeTargetLanguage(outputLanguage)
        guard normalizedOutputLanguage.isEmpty == false else {
            throw TranslationStorageError.outputLanguageRequired
        }

        let normalizedSourceContentHash = sourceContentHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSourceContentHash.isEmpty == false else {
            throw TranslationStorageError.sourceContentHashRequired
        }

        let normalizedSegmenterVersion = segmenterVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSegmenterVersion.isEmpty == false else {
            throw TranslationStorageError.segmenterVersionRequired
        }

        let snapshot = try encodeTranslationRuntimeSnapshot(runtimeParameterSnapshot)
        let now = Date()

        return try await database.write { db in
            // Keep exactly one row per slot identity (entry + language + content hash + segmenter).
            let replacedRunIDs = try Int64.fetchAll(
                db,
                TranslationResult
                    .select(Column("taskRunId"))
                    .filter(Column("entryId") == entryId)
                    .filter(Column("targetLanguage") == normalizedTargetLanguage)
                    .filter(Column("sourceContentHash") == normalizedSourceContentHash)
                    .filter(Column("segmenterVersion") == normalizedSegmenterVersion)
            )
            _ = try deleteTranslationRunIDs(replacedRunIDs, in: db)

            var run = AgentTaskRun(
                id: nil,
                entryId: entryId,
                taskType: .translation,
                status: .running,
                agentProfileId: agentProfileId,
                providerProfileId: providerProfileId,
                modelProfileId: modelProfileId,
                promptVersion: normalizeTranslationOptional(promptVersion),
                targetLanguage: normalizedTargetLanguage,
                templateId: normalizeTranslationOptional(templateId),
                templateVersion: normalizeTranslationOptional(templateVersion),
                runtimeParameterSnapshot: snapshot,
                durationMs: durationMs,
                createdAt: now,
                updatedAt: now
            )
            try run.insert(db)

            guard let runID = run.id else {
                throw TranslationStorageError.missingTaskRunID
            }

            var result = TranslationResult(
                taskRunId: runID,
                entryId: entryId,
                targetLanguage: normalizedTargetLanguage,
                sourceContentHash: normalizedSourceContentHash,
                segmenterVersion: normalizedSegmenterVersion,
                outputLanguage: normalizedOutputLanguage,
                runStatus: .running,
                createdAt: now,
                updatedAt: now
            )
            try result.insert(db)

            return runID
        }
    }

    func persistTranslationSegmentCheckpoint(
        taskRunId: Int64,
        segment: TranslationPersistedSegmentInput
    ) async throws {
        let normalizedTranslatedText = segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTranslatedText.isEmpty == false else {
            throw TranslationStorageError.missingTranslatedSegment(sourceSegmentId: segment.sourceSegmentId)
        }

        try await database.write { db in
            guard let result = try TranslationResult
                .filter(Column("taskRunId") == taskRunId)
                .fetchOne(db) else {
                throw TranslationStorageError.checkpointRunNotFound(taskRunId: taskRunId)
            }
            guard result.runStatus == .running else {
                throw TranslationStorageError.checkpointRunNotRunning(taskRunId: taskRunId)
            }
            guard let run = try AgentTaskRun
                .filter(Column("id") == taskRunId)
                .fetchOne(db) else {
                throw TranslationStorageError.checkpointRunNotFound(taskRunId: taskRunId)
            }
            guard run.status == .running else {
                throw TranslationStorageError.checkpointRunNotRunning(taskRunId: taskRunId)
            }

            let now = Date()
            if var existing = try TranslationSegment
                .filter(Column("taskRunId") == taskRunId)
                .filter(Column("sourceSegmentId") == segment.sourceSegmentId)
                .fetchOne(db) {
                existing.orderIndex = segment.orderIndex
                existing.sourceTextSnapshot = normalizeTranslationOptional(segment.sourceTextSnapshot)
                existing.translatedText = normalizedTranslatedText
                existing.updatedAt = now
                try existing.update(db)
            } else {
                var row = TranslationSegment(
                    taskRunId: taskRunId,
                    sourceSegmentId: segment.sourceSegmentId,
                    orderIndex: segment.orderIndex,
                    sourceTextSnapshot: normalizeTranslationOptional(segment.sourceTextSnapshot),
                    translatedText: normalizedTranslatedText,
                    createdAt: now,
                    updatedAt: now
                )
                try row.insert(db)
            }

            _ = try TranslationResult
                .filter(Column("taskRunId") == taskRunId)
                .updateAll(
                    db,
                    [Column("updatedAt").set(to: now)]
                )
        }
    }

    @discardableResult
    func discardRunningTranslationCheckpoint(taskRunId: Int64) async throws -> Bool {
        try await database.write { db in
            guard let result = try TranslationResult
                .filter(Column("taskRunId") == taskRunId)
                .fetchOne(db) else {
                return false
            }
            guard result.runStatus == .running else {
                return false
            }
            _ = try deleteTranslationRunIDs([taskRunId], in: db)
            return true
        }
    }

    @discardableResult
    func persistSuccessfulTranslationResult(
        entryId: Int64,
        agentProfileId: Int64?,
        providerProfileId: Int64?,
        modelProfileId: Int64?,
        promptVersion: String?,
        targetLanguage: String,
        sourceContentHash: String,
        segmenterVersion: String,
        outputLanguage: String,
        segments: [TranslationPersistedSegmentInput],
        templateId: String?,
        templateVersion: String?,
        runtimeParameterSnapshot: [String: String],
        durationMs: Int?,
        checkpointTaskRunId: Int64? = nil
    ) async throws -> TranslationStoredRecord {
        let normalizedTargetLanguage = TranslationStorageQueryHelper.normalizeTargetLanguage(targetLanguage)
        guard normalizedTargetLanguage.isEmpty == false else {
            throw TranslationStorageError.targetLanguageRequired
        }

        let normalizedOutputLanguage = TranslationStorageQueryHelper.normalizeTargetLanguage(outputLanguage)
        guard normalizedOutputLanguage.isEmpty == false else {
            throw TranslationStorageError.outputLanguageRequired
        }

        let normalizedSourceContentHash = sourceContentHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSourceContentHash.isEmpty == false else {
            throw TranslationStorageError.sourceContentHashRequired
        }

        let normalizedSegmenterVersion = segmenterVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSegmenterVersion.isEmpty == false else {
            throw TranslationStorageError.segmenterVersionRequired
        }

        guard segments.isEmpty == false else {
            throw TranslationStorageError.segmentsRequired
        }

        let snapshot = try encodeTranslationRuntimeSnapshot(runtimeParameterSnapshot)
        let now = Date()

        return try await database.write { db in
            if let checkpointTaskRunId {
                if let finalizedRecord = try finalizeRunningTranslationCheckpoint(
                    checkpointTaskRunId: checkpointTaskRunId,
                    entryId: entryId,
                    agentProfileId: agentProfileId,
                    providerProfileId: providerProfileId,
                    modelProfileId: modelProfileId,
                    promptVersion: promptVersion,
                    targetLanguage: normalizedTargetLanguage,
                    sourceContentHash: normalizedSourceContentHash,
                    segmenterVersion: normalizedSegmenterVersion,
                    outputLanguage: normalizedOutputLanguage,
                    segments: segments,
                    templateId: templateId,
                    templateVersion: templateVersion,
                    runtimeSnapshot: snapshot,
                    durationMs: durationMs,
                    now: now,
                    db: db
                ) {
                    _ = try performTranslationStorageCapEviction(in: db, limit: 2000)
                    return finalizedRecord
                }
            }
            if let slotRunningRunID = try Int64.fetchOne(
                db,
                TranslationResult
                    .select(Column("taskRunId"))
                    .filter(Column("entryId") == entryId)
                    .filter(Column("targetLanguage") == normalizedTargetLanguage)
                    .filter(Column("sourceContentHash") == normalizedSourceContentHash)
                    .filter(Column("segmenterVersion") == normalizedSegmenterVersion)
                    .filter(Column("runStatus") == TranslationResultRunStatus.running.rawValue)
                    .order(Column("updatedAt").desc)
                    .order(Column("createdAt").desc)
            ) {
                if let finalizedRecord = try finalizeRunningTranslationCheckpoint(
                    checkpointTaskRunId: slotRunningRunID,
                    entryId: entryId,
                    agentProfileId: agentProfileId,
                    providerProfileId: providerProfileId,
                    modelProfileId: modelProfileId,
                    promptVersion: promptVersion,
                    targetLanguage: normalizedTargetLanguage,
                    sourceContentHash: normalizedSourceContentHash,
                    segmenterVersion: normalizedSegmenterVersion,
                    outputLanguage: normalizedOutputLanguage,
                    segments: segments,
                    templateId: templateId,
                    templateVersion: templateVersion,
                    runtimeSnapshot: snapshot,
                    durationMs: durationMs,
                    now: now,
                    db: db
                ) {
                    _ = try performTranslationStorageCapEviction(in: db, limit: 2000)
                    return finalizedRecord
                }
            }

            var run = AgentTaskRun(
                id: nil,
                entryId: entryId,
                taskType: .translation,
                status: .succeeded,
                agentProfileId: agentProfileId,
                providerProfileId: providerProfileId,
                modelProfileId: modelProfileId,
                promptVersion: normalizeTranslationOptional(promptVersion),
                targetLanguage: normalizedTargetLanguage,
                templateId: normalizeTranslationOptional(templateId),
                templateVersion: normalizeTranslationOptional(templateVersion),
                runtimeParameterSnapshot: snapshot,
                durationMs: durationMs,
                createdAt: now,
                updatedAt: now
            )
            try run.insert(db)

            guard let runID = run.id else {
                throw TranslationStorageError.missingTaskRunID
            }

            let replacedRunIDs = try Int64.fetchAll(
                db,
                TranslationResult
                    .select(Column("taskRunId"))
                    .filter(Column("entryId") == entryId)
                    .filter(Column("targetLanguage") == normalizedTargetLanguage)
                    .filter(Column("sourceContentHash") == normalizedSourceContentHash)
                    .filter(Column("segmenterVersion") == normalizedSegmenterVersion)
            )

            let obsoleteRunIDs = replacedRunIDs.filter { $0 != runID }
            _ = try deleteTranslationRunIDs(obsoleteRunIDs, in: db)

            var result = TranslationResult(
                taskRunId: runID,
                entryId: entryId,
                targetLanguage: normalizedTargetLanguage,
                sourceContentHash: normalizedSourceContentHash,
                segmenterVersion: normalizedSegmenterVersion,
                outputLanguage: normalizedOutputLanguage,
                runStatus: .succeeded,
                createdAt: now,
                updatedAt: now
            )
            try result.insert(db)

            let sortedSegments = segments.sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }
            for segment in sortedSegments {
                let normalizedTranslatedText = segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalizedTranslatedText.isEmpty == false else {
                    throw TranslationStorageError.missingTranslatedSegment(sourceSegmentId: segment.sourceSegmentId)
                }
                var row = TranslationSegment(
                    taskRunId: runID,
                    sourceSegmentId: segment.sourceSegmentId,
                    orderIndex: segment.orderIndex,
                    sourceTextSnapshot: normalizeTranslationOptional(segment.sourceTextSnapshot),
                    translatedText: normalizedTranslatedText,
                    createdAt: now,
                    updatedAt: now
                )
                try row.insert(db)
            }

            _ = try performTranslationStorageCapEviction(in: db, limit: 2000)

            let persistedSegments = try TranslationSegment
                .filter(Column("taskRunId") == runID)
                .order(Column("orderIndex").asc)
                .fetchAll(db)

            return TranslationStoredRecord(
                run: run,
                result: result,
                segments: persistedSegments,
                isCheckpointRunning: false,
                isCheckpointOrphaned: false
            )
        }
    }

    @discardableResult
    func enforceTranslationStorageCap(limit: Int = 2000) async throws -> Int {
        try await database.write { db in
            try performTranslationStorageCapEviction(in: db, limit: limit)
        }
    }
}

private func performTranslationStorageCapEviction(in db: Database, limit: Int) throws -> Int {
    let safeLimit = max(limit, 0)
    let totalCount = try TranslationResult.fetchCount(db)
    let overflow = totalCount - safeLimit
    guard overflow > 0 else {
        return 0
    }

    let staleRunIDs = try Int64.fetchAll(
        db,
        TranslationResult
            .select(Column("taskRunId"))
            .order(Column("updatedAt").asc)
            .order(Column("createdAt").asc)
            .limit(overflow)
    )

    _ = try deleteTranslationRunIDs(staleRunIDs, in: db)

    return staleRunIDs.count
}

private func finalizeRunningTranslationCheckpoint(
    checkpointTaskRunId: Int64,
    entryId: Int64,
    agentProfileId: Int64?,
    providerProfileId: Int64?,
    modelProfileId: Int64?,
    promptVersion: String?,
    targetLanguage: String,
    sourceContentHash: String,
    segmenterVersion: String,
    outputLanguage: String,
    segments: [TranslationPersistedSegmentInput],
    templateId: String?,
    templateVersion: String?,
    runtimeSnapshot: String?,
    durationMs: Int?,
    now: Date,
    db: Database
) throws -> TranslationStoredRecord? {
    guard var run = try AgentTaskRun
        .filter(Column("id") == checkpointTaskRunId)
        .fetchOne(db) else {
        return nil
    }
    guard var result = try TranslationResult
        .filter(Column("taskRunId") == checkpointTaskRunId)
        .fetchOne(db) else {
        return nil
    }
    guard result.runStatus == .running else {
        return nil
    }

    run.entryId = entryId
    run.taskType = .translation
    run.status = .succeeded
    run.agentProfileId = agentProfileId
    run.providerProfileId = providerProfileId
    run.modelProfileId = modelProfileId
    run.promptVersion = normalizeTranslationOptional(promptVersion)
    run.targetLanguage = targetLanguage
    run.templateId = normalizeTranslationOptional(templateId)
    run.templateVersion = normalizeTranslationOptional(templateVersion)
    run.runtimeParameterSnapshot = runtimeSnapshot
    run.durationMs = durationMs
    run.updatedAt = now
    try run.update(db)

    result.entryId = entryId
    result.targetLanguage = targetLanguage
    result.sourceContentHash = sourceContentHash
    result.segmenterVersion = segmenterVersion
    result.outputLanguage = outputLanguage
    result.runStatus = .succeeded
    result.updatedAt = now
    try result.update(db)

    _ = try TranslationSegment
        .filter(Column("taskRunId") == checkpointTaskRunId)
        .deleteAll(db)

    let sortedSegments = segments.sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }
    for segment in sortedSegments {
        let normalizedTranslatedText = segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTranslatedText.isEmpty == false else {
            throw TranslationStorageError.missingTranslatedSegment(sourceSegmentId: segment.sourceSegmentId)
        }
        var row = TranslationSegment(
            taskRunId: checkpointTaskRunId,
            sourceSegmentId: segment.sourceSegmentId,
            orderIndex: segment.orderIndex,
            sourceTextSnapshot: normalizeTranslationOptional(segment.sourceTextSnapshot),
            translatedText: normalizedTranslatedText,
            createdAt: now,
            updatedAt: now
        )
        try row.insert(db)
    }

    let persistedSegments = try TranslationSegment
        .filter(Column("taskRunId") == checkpointTaskRunId)
        .order(Column("orderIndex").asc)
        .fetchAll(db)

    return TranslationStoredRecord(
        run: run,
        result: result,
        segments: persistedSegments,
        isCheckpointRunning: false,
        isCheckpointOrphaned: false
    )
}

@discardableResult
private func deleteTranslationRunIDs(_ runIDs: [Int64], in db: Database) throws -> Int {
    guard runIDs.isEmpty == false else {
        return 0
    }

    _ = try TranslationResult
        .filter(runIDs.contains(Column("taskRunId")))
        .deleteAll(db)
    _ = try AgentTaskRun
        .filter(runIDs.contains(Column("id")))
        .deleteAll(db)

    return runIDs.count
}

private func encodeTranslationRuntimeSnapshot(_ snapshot: [String: String]) throws -> String? {
    guard snapshot.isEmpty == false else {
        return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshot)
    return String(data: data, encoding: .utf8)
}

private func normalizeTranslationOptional(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}
