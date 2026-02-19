import Foundation
import GRDB

struct AITranslationStoredRecord: Sendable {
    let run: AITaskRun
    let result: AITranslationResult
    let segments: [AITranslationSegment]
}

enum AITranslationStorageQueryHelper {
    static func normalizeTargetLanguage(_ targetLanguage: String) -> String {
        SummaryLanguageOption.normalizeCode(targetLanguage)
    }

    static func makeSlotKey(
        entryId: Int64,
        targetLanguage: String,
        sourceContentHash: String,
        segmenterVersion: String
    ) -> AITranslationSlotKey {
        AITranslationSlotKey(
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
        segmenterVersion: String = AITranslationSegmentationContract.segmenterVersion
    ) -> AITranslationSlotKey {
        AITranslationStorageQueryHelper.makeSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage,
            sourceContentHash: sourceContentHash,
            segmenterVersion: segmenterVersion
        )
    }

    func loadTranslationRecord(slotKey: AITranslationSlotKey) async throws -> AITranslationStoredRecord? {
        let normalizedLanguage = AITranslationStorageQueryHelper.normalizeTargetLanguage(slotKey.targetLanguage)

        return try await database.read { db in
            guard let result = try AITranslationResult
                .filter(Column("entryId") == slotKey.entryId)
                .filter(Column("targetLanguage") == normalizedLanguage)
                .filter(Column("sourceContentHash") == slotKey.sourceContentHash)
                .filter(Column("segmenterVersion") == slotKey.segmenterVersion)
                .fetchOne(db) else {
                return nil
            }

            guard let run = try AITaskRun
                .filter(Column("id") == result.taskRunId)
                .fetchOne(db) else {
                return nil
            }

            let segments = try AITranslationSegment
                .filter(Column("taskRunId") == result.taskRunId)
                .order(Column("orderIndex").asc)
                .fetchAll(db)

            return AITranslationStoredRecord(run: run, result: result, segments: segments)
        }
    }

    func translationSourceSegments(entryId: Int64) async throws -> ReaderSourceSegmentsSnapshot? {
        guard let markdown = try await summarySourceMarkdown(entryId: entryId) else {
            return nil
        }
        return try AITranslationSegmentExtractor.extract(entryId: entryId, markdown: markdown)
    }
}
