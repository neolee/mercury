//
//  AppModel+SummaryStorage.swift
//  Mercury
//
//  Created by Codex on 2026/2/18.
//

import Foundation
import GRDB

enum SummaryStorageError: LocalizedError {
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

struct SummaryStoredRecord {
    let run: AgentTaskRun
    let result: SummaryResult
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
        detailLevel: SummaryDetailLevel,
        outputLanguage: String,
        outputText: String,
        templateId: String?,
        templateVersion: String?,
        runtimeParameterSnapshot: [String: String],
        durationMs: Int?
    ) async throws -> SummaryStoredRecord {
        let normalizedTargetLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTargetLanguage.isEmpty == false else {
            throw SummaryStorageError.targetLanguageRequired
        }

        let normalizedOutputLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedOutputLanguage.isEmpty == false else {
            throw SummaryStorageError.outputLanguageRequired
        }

        let normalizedOutputText = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedOutputText.isEmpty == false else {
            throw SummaryStorageError.outputTextRequired
        }

        let snapshot = try encodeRuntimeParameterSnapshot(runtimeParameterSnapshot)
        let now = Date()

        return try await database.write { db in
            var run = AgentTaskRun(
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
                throw SummaryStorageError.missingTaskRunID
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

            var result = SummaryResult(
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

            _ = try performSummaryStorageCapEviction(in: db, limit: 2000)

            return SummaryStoredRecord(run: run, result: result)
        }
    }

    func loadSummaryRecord(
        entryId: Int64,
        targetLanguage: String,
        detailLevel: SummaryDetailLevel
    ) async throws -> SummaryStoredRecord? {
        let normalizedTargetLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTargetLanguage.isEmpty == false else {
            return nil
        }

        return try await database.read { db in
            guard let result = try SummaryResult
                .filter(Column("entryId") == entryId)
                .filter(Column("targetLanguage") == normalizedTargetLanguage)
                .filter(Column("detailLevel") == detailLevel.rawValue)
                .fetchOne(db) else {
                return nil
            }

            guard let run = try AgentTaskRun
                .filter(Column("id") == result.taskRunId)
                .fetchOne(db) else {
                return nil
            }

            return SummaryStoredRecord(run: run, result: result)
        }
    }

    func loadLatestSummaryRecord(entryId: Int64) async throws -> SummaryStoredRecord? {
        try await database.read { db in
            guard let result = try SummaryResult
                .filter(Column("entryId") == entryId)
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

            return SummaryStoredRecord(run: run, result: result)
        }
    }

    @discardableResult
    func clearSummaryRecord(
        entryId: Int64,
        targetLanguage: String,
        detailLevel: SummaryDetailLevel
    ) async throws -> Bool {
        let normalizedTargetLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTargetLanguage.isEmpty == false else {
            return false
        }

        return try await database.write { db in
            let runIDs = try Int64.fetchAll(
                db,
                sql: """
                SELECT taskRunId
                FROM ai_summary_result
                WHERE entryId = ? AND targetLanguage = ? AND detailLevel = ?
                """,
                arguments: [entryId, normalizedTargetLanguage, detailLevel.rawValue]
            )

            guard runIDs.isEmpty == false else {
                return false
            }

            _ = try deleteSummaryRunIDs(runIDs, in: db)
            return true
        }
    }

    @discardableResult
    func enforceSummaryStorageCap(limit: Int = 2000) async throws -> Int {
        try await database.write { db in
            try performSummaryStorageCapEviction(in: db, limit: limit)
        }
    }
}

private func performSummaryStorageCapEviction(in db: Database, limit: Int) throws -> Int {
    let safeLimit = max(limit, 0)
    let totalCount = try SummaryResult.fetchCount(db)
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

    _ = try SummaryResult
        .filter(runIDs.contains(Column("taskRunId")))
        .deleteAll(db)
    _ = try AgentTaskRun
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
