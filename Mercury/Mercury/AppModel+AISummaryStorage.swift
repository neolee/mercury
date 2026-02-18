//
//  AppModel+AISummaryStorage.swift
//  Mercury
//
//  Created by Codex on 2026/2/18.
//

import Foundation
import GRDB

private let aiSummaryStorageCapDefaultLimit = 2000

enum AISummaryStorageError: LocalizedError {
    case outputTextRequired
    case targetLanguageRequired
    case outputLanguageRequired
    case missingTaskRunID

    var errorDescription: String? {
        switch self {
        case .outputTextRequired:
            return "Summary output text is required."
        case .targetLanguageRequired:
            return "Target language is required."
        case .outputLanguageRequired:
            return "Output language is required."
        case .missingTaskRunID:
            return "Task run ID is missing after insert."
        }
    }
}

struct AISummaryStoredRecord {
    let run: AITaskRun
    let result: AISummaryResult
}

extension AppModel {
    @discardableResult
    func persistSuccessfulSummaryResult(
        entryId: Int64,
        assistantProfileId: Int64?,
        providerProfileId: Int64?,
        modelProfileId: Int64?,
        promptVersion: String?,
        targetLanguage: String,
        detailLevel: AISummaryDetailLevel,
        outputLanguage: String,
        outputText: String,
        templateId: String?,
        templateVersion: String?,
        runtimeParameterSnapshot: [String: String],
        durationMs: Int?
    ) async throws -> AISummaryStoredRecord {
        let normalizedTargetLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTargetLanguage.isEmpty == false else {
            throw AISummaryStorageError.targetLanguageRequired
        }

        let normalizedOutputLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedOutputLanguage.isEmpty == false else {
            throw AISummaryStorageError.outputLanguageRequired
        }

        let normalizedOutputText = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedOutputText.isEmpty == false else {
            throw AISummaryStorageError.outputTextRequired
        }

        let snapshot = try encodeRuntimeParameterSnapshot(runtimeParameterSnapshot)
        let now = Date()

        return try await database.write { db in
            var run = AITaskRun(
                id: nil,
                entryId: entryId,
                taskType: .summary,
                status: .succeeded,
                assistantProfileId: assistantProfileId,
                providerProfileId: providerProfileId,
                modelProfileId: modelProfileId,
                promptVersion: normalizeOptional(promptVersion),
                targetLanguage: normalizedTargetLanguage,
                templateId: normalizeOptional(templateId),
                templateVersion: normalizeOptional(templateVersion),
                runtimeParameterSnapshot: snapshot,
                durationMs: durationMs,
                createdAt: now,
                updatedAt: now
            )
            try run.insert(db)

            guard let runID = run.id else {
                throw AISummaryStorageError.missingTaskRunID
            }

            let replacedRunIDs = try Int64.fetchAll(
                db,
                sql: """
                SELECT taskRunId
                FROM ai_summary_result
                WHERE entryId = ? AND targetLanguage = ? AND detailLevel = ?
                """,
                arguments: [entryId, normalizedTargetLanguage, detailLevel.rawValue]
            )

            let obsoleteRunIDs = replacedRunIDs.filter { $0 != runID }
            _ = try deleteSummaryRunIDs(obsoleteRunIDs, in: db)

            var result = AISummaryResult(
                taskRunId: runID,
                entryId: entryId,
                targetLanguage: normalizedTargetLanguage,
                detailLevel: detailLevel,
                outputLanguage: normalizedOutputLanguage,
                text: normalizedOutputText,
                createdAt: now,
                updatedAt: now
            )
            try result.insert(db)

            _ = try performAISummaryStorageCapEviction(in: db, limit: aiSummaryStorageCapDefaultLimit)

            return AISummaryStoredRecord(run: run, result: result)
        }
    }

    func loadSummaryRecord(
        entryId: Int64,
        targetLanguage: String,
        detailLevel: AISummaryDetailLevel
    ) async throws -> AISummaryStoredRecord? {
        let normalizedTargetLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTargetLanguage.isEmpty == false else {
            return nil
        }

        return try await database.read { db in
            guard let result = try AISummaryResult
                .filter(Column("entryId") == entryId)
                .filter(Column("targetLanguage") == normalizedTargetLanguage)
                .filter(Column("detailLevel") == detailLevel.rawValue)
                .fetchOne(db) else {
                return nil
            }

            guard let run = try AITaskRun
                .filter(Column("id") == result.taskRunId)
                .fetchOne(db) else {
                return nil
            }

            return AISummaryStoredRecord(run: run, result: result)
        }
    }

    @discardableResult
    func enforceAISummaryStorageCap(limit: Int = aiSummaryStorageCapDefaultLimit) async throws -> Int {
        try await database.write { db in
            try performAISummaryStorageCapEviction(in: db, limit: limit)
        }
    }
}

private func performAISummaryStorageCapEviction(in db: Database, limit: Int) throws -> Int {
    let safeLimit = max(limit, 0)
    let totalCount = try AISummaryResult.fetchCount(db)
    let overflow = totalCount - safeLimit
    guard overflow > 0 else {
        return 0
    }

    let staleRunIDs = try Int64.fetchAll(
        db,
        sql: """
        SELECT taskRunId
        FROM ai_summary_result
        ORDER BY updatedAt ASC, createdAt ASC
        LIMIT ?
        """,
        arguments: [overflow]
    )

    _ = try deleteSummaryRunIDs(staleRunIDs, in: db)

    return staleRunIDs.count
}

@discardableResult
private func deleteSummaryRunIDs(_ runIDs: [Int64], in db: Database) throws -> Int {
    guard runIDs.isEmpty == false else {
        return 0
    }

    _ = try AISummaryResult
        .filter(runIDs.contains(Column("taskRunId")))
        .deleteAll(db)
    _ = try AITaskRun
        .filter(runIDs.contains(Column("id")))
        .deleteAll(db)

    return runIDs.count
}

private func encodeRuntimeParameterSnapshot(_ snapshot: [String: String]) throws -> String? {
    guard snapshot.isEmpty == false else {
        return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshot)
    return String(data: data, encoding: .utf8)
}

private func normalizeOptional(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}
