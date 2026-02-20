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
        }
    }
}

struct TranslationStoredRecord: Sendable {
    let run: AgentTaskRun
    let result: TranslationResult
    let segments: [TranslationSegment]
}

struct TranslationPersistedSegmentInput: Sendable {
    let sourceSegmentId: String
    let orderIndex: Int
    let sourceTextSnapshot: String?
    let translatedText: String
}

enum TranslationStorageQueryHelper {
    static func normalizeTargetLanguage(_ targetLanguage: String) -> String {
        SummaryLanguageOption.normalizeCode(targetLanguage)
    }

    static func makeSlotKey(
        entryId: Int64,
        targetLanguage: String,
        sourceContentHash: String,
        segmenterVersion: String
    ) -> TranslationSlotKey {
        TranslationSlotKey(
            entryId: entryId,
            targetLanguage: normalizeTargetLanguage(targetLanguage),
            sourceContentHash: sourceContentHash,
            segmenterVersion: segmenterVersion
        )
    }
}

extension AppModel {
    func makeTranslationSlotKey(
        entryId: Int64,
        targetLanguage: String,
        sourceContentHash: String,
        segmenterVersion: String = TranslationSegmentationContract.segmenterVersion
    ) -> TranslationSlotKey {
        TranslationStorageQueryHelper.makeSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage,
            sourceContentHash: sourceContentHash,
            segmenterVersion: segmenterVersion
        )
    }

    func loadTranslationRecord(slotKey: TranslationSlotKey) async throws -> TranslationStoredRecord? {
        let normalizedLanguage = TranslationStorageQueryHelper.normalizeTargetLanguage(slotKey.targetLanguage)

        return try await database.read { db in
            guard let result = try TranslationResult
                .filter(Column("entryId") == slotKey.entryId)
                .filter(Column("targetLanguage") == normalizedLanguage)
                .filter(Column("sourceContentHash") == slotKey.sourceContentHash)
                .filter(Column("segmenterVersion") == slotKey.segmenterVersion)
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

            return TranslationStoredRecord(run: run, result: result, segments: segments)
        }
    }

    @discardableResult
    func deleteTranslationRecord(slotKey: TranslationSlotKey) async throws -> Bool {
        let normalizedLanguage = TranslationStorageQueryHelper.normalizeTargetLanguage(slotKey.targetLanguage)

        return try await database.write { db in
            let runIDs = try Int64.fetchAll(
                db,
                sql: """
                SELECT taskRunId
                FROM ai_translation_result
                WHERE entryId = ? AND targetLanguage = ? AND sourceContentHash = ? AND segmenterVersion = ?
                """,
                arguments: [
                    slotKey.entryId,
                    normalizedLanguage,
                    slotKey.sourceContentHash,
                    slotKey.segmenterVersion
                ]
            )
            let deleted = try deleteTranslationRunIDs(runIDs, in: db)
            return deleted > 0
        }
    }

    func translationSourceSegments(entryId: Int64) async throws -> ReaderSourceSegmentsSnapshot? {
        guard let markdown = try await summarySourceMarkdown(entryId: entryId) else {
            return nil
        }
        return try TranslationSegmentExtractor.extract(entryId: entryId, markdown: markdown)
    }

    @discardableResult
    func persistSuccessfulTranslationResult(
        entryId: Int64,
        assistantProfileId: Int64?,
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
        durationMs: Int?
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
            var run = AgentTaskRun(
                id: nil,
                entryId: entryId,
                taskType: .translation,
                status: .succeeded,
                assistantProfileId: assistantProfileId,
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
                sql: """
                SELECT taskRunId
                FROM ai_translation_result
                WHERE entryId = ? AND targetLanguage = ? AND sourceContentHash = ? AND segmenterVersion = ?
                """,
                arguments: [entryId, normalizedTargetLanguage, normalizedSourceContentHash, normalizedSegmenterVersion]
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

            _ = try performAITranslationStorageCapEviction(in: db, limit: 2000)

            let persistedSegments = try TranslationSegment
                .filter(Column("taskRunId") == runID)
                .order(Column("orderIndex").asc)
                .fetchAll(db)

            return TranslationStoredRecord(run: run, result: result, segments: persistedSegments)
        }
    }

    @discardableResult
    func enforceAITranslationStorageCap(limit: Int = 2000) async throws -> Int {
        try await database.write { db in
            try performAITranslationStorageCapEviction(in: db, limit: limit)
        }
    }
}

private func performAITranslationStorageCapEviction(in db: Database, limit: Int) throws -> Int {
    let safeLimit = max(limit, 0)
    let totalCount = try TranslationResult.fetchCount(db)
    let overflow = totalCount - safeLimit
    guard overflow > 0 else {
        return 0
    }

    let staleRunIDs = try Int64.fetchAll(
        db,
        sql: """
        SELECT taskRunId
        FROM ai_translation_result
        ORDER BY updatedAt ASC, createdAt ASC
        LIMIT ?
        """,
        arguments: [overflow]
    )

    _ = try deleteTranslationRunIDs(staleRunIDs, in: db)

    return staleRunIDs.count
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
