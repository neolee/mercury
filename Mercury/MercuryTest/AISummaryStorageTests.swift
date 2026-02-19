import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("AI Summary Storage")
@MainActor
struct AISummaryStorageTests {
    @Test("A/B workflow + global cap + cleanup")
    func summaryStorageWorkflow() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let databaseManager = try DatabaseManager(path: dbPath)
        let appModel = AppModel(
            databaseManager: databaseManager,
            credentialStore: InMemoryCredentialStore()
        )

        let (entryA, entryB) = try await seedTwoEntries(using: appModel)
        let targetLanguage = "en"
        let detailLevel: AISummaryDetailLevel = .medium
        let step1Snapshot = ["mode": "step-1", "detail": detailLevel.rawValue]

        // Step 1: insert A summary slot
        let first = try await appModel.persistSuccessfulSummaryResult(
            entryId: entryA,
            assistantProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "summary-agent-v1",
            targetLanguage: targetLanguage,
            detailLevel: detailLevel,
            outputLanguage: targetLanguage,
            outputText: "summary A v1",
            templateId: "summary.default",
            templateVersion: "v1",
            runtimeParameterSnapshot: step1Snapshot,
            durationMs: 100
        )
        let firstResultTargetLanguage = first.result.targetLanguage
        let firstResultDetailLevel = first.result.detailLevel
        let firstResultEntryID = first.result.entryId
        let firstRunTemplateID = first.run.templateId
        let firstRunTemplateVersion = first.run.templateVersion
        let firstRunRuntimeSnapshot = first.run.runtimeParameterSnapshot
        let firstResultRunID = first.result.taskRunId

        #expect(firstResultTargetLanguage == targetLanguage)
        #expect(firstResultDetailLevel == detailLevel)
        #expect(firstResultEntryID == entryA)
        #expect(firstRunTemplateID == "summary.default")
        #expect(firstRunTemplateVersion == "v1")
        #expect(firstRunRuntimeSnapshot == "{\"detail\":\"medium\",\"mode\":\"step-1\"}")
        #expect(try await countSummarySlot(appModel, entryId: entryA, targetLanguage: targetLanguage, detailLevel: detailLevel) == 1)
        #expect(try await countSummaryTotal(appModel) == 1)
        #expect(try await countSummaryTaskRunTotal(appModel) == 1)

        // Step 2: insert same A slot again, slot should remain single and old run should be replaced
        let second = try await appModel.persistSuccessfulSummaryResult(
            entryId: entryA,
            assistantProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "summary-agent-v1",
            targetLanguage: targetLanguage,
            detailLevel: detailLevel,
            outputLanguage: targetLanguage,
            outputText: "summary A v2",
            templateId: "summary.default",
            templateVersion: "v1",
            runtimeParameterSnapshot: [:],
            durationMs: 120
        )
        let secondResultRunID = second.result.taskRunId
        #expect(secondResultRunID != firstResultRunID)
        #expect(try await countSummarySlot(appModel, entryId: entryA, targetLanguage: targetLanguage, detailLevel: detailLevel) == 1)
        #expect(try await taskRunExists(appModel, runId: firstResultRunID) == false)
        #expect(try await countSummaryTaskRunTotal(appModel) == 1)

        // Step 3: add B, enforce global cap=1, then verify older A removed and B kept
        _ = try await appModel.persistSuccessfulSummaryResult(
            entryId: entryB,
            assistantProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "summary-agent-v1",
            targetLanguage: targetLanguage,
            detailLevel: detailLevel,
            outputLanguage: targetLanguage,
            outputText: "summary B v1",
            templateId: "summary.default",
            templateVersion: "v1",
            runtimeParameterSnapshot: [:],
            durationMs: 90
        )
        #expect(try await countSummaryTotal(appModel) == 2)
        let removedFirstCap = try await appModel.enforceAISummaryStorageCap(limit: 1)
        #expect(removedFirstCap == 1)
        #expect(try await appModel.loadSummaryRecord(entryId: entryA, targetLanguage: targetLanguage, detailLevel: detailLevel) == nil)
        #expect(try await appModel.loadSummaryRecord(entryId: entryB, targetLanguage: targetLanguage, detailLevel: detailLevel) != nil)

        // Optional stronger check: insert A again and cap again, now B should be evicted
        _ = try await appModel.persistSuccessfulSummaryResult(
            entryId: entryA,
            assistantProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "summary-agent-v1",
            targetLanguage: targetLanguage,
            detailLevel: detailLevel,
            outputLanguage: targetLanguage,
            outputText: "summary A v3",
            templateId: "summary.default",
            templateVersion: "v1",
            runtimeParameterSnapshot: [:],
            durationMs: 110
        )
        let removedSecondCap = try await appModel.enforceAISummaryStorageCap(limit: 1)
        #expect(removedSecondCap == 1)
        #expect(try await appModel.loadSummaryRecord(entryId: entryA, targetLanguage: targetLanguage, detailLevel: detailLevel) != nil)
        #expect(try await appModel.loadSummaryRecord(entryId: entryB, targetLanguage: targetLanguage, detailLevel: detailLevel) == nil)

        // Step 4: cleanup test records
        let cleanup = try await appModel.database.write { db in
            let removedSummary = try AISummaryResult.deleteAll(db)
            let removedRuns = try AITaskRun
                .filter(Column("taskType") == AITaskType.summary.rawValue)
                .deleteAll(db)
            return (removedSummary, removedRuns)
        }
        #expect(cleanup.0 >= 1)
        #expect(cleanup.1 >= 1)
        #expect(try await countSummaryTotal(appModel) == 0)
    }

    @Test("Clear summary removes current slot payload and task run")
    func clearSummaryRecordRemovesSlot() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let databaseManager = try DatabaseManager(path: dbPath)
        let appModel = AppModel(
            databaseManager: databaseManager,
            credentialStore: InMemoryCredentialStore()
        )

        let (entryA, _) = try await seedTwoEntries(using: appModel)
        let targetLanguage = "en"
        let detailLevel: AISummaryDetailLevel = .medium

        let first = try await appModel.persistSuccessfulSummaryResult(
            entryId: entryA,
            assistantProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "summary-agent-v1",
            targetLanguage: targetLanguage,
            detailLevel: detailLevel,
            outputLanguage: targetLanguage,
            outputText: "to be cleared",
            templateId: "summary.default",
            templateVersion: "v1",
            runtimeParameterSnapshot: [:],
            durationMs: 50
        )
        guard let firstRunID = first.run.id else {
            Issue.record("Expected task run ID after summary insert.")
            return
        }
        #expect(try await countSummarySlot(appModel, entryId: entryA, targetLanguage: targetLanguage, detailLevel: detailLevel) == 1)
        #expect(try await taskRunExists(appModel, runId: firstRunID) == true)

        let cleared = try await appModel.clearSummaryRecord(
            entryId: entryA,
            targetLanguage: targetLanguage,
            detailLevel: detailLevel
        )
        #expect(cleared == true)
        #expect(try await countSummarySlot(appModel, entryId: entryA, targetLanguage: targetLanguage, detailLevel: detailLevel) == 0)
        #expect(try await taskRunExists(appModel, runId: firstRunID) == false)
    }

    private func seedTwoEntries(using appModel: AppModel) async throws -> (Int64, Int64) {
        try await appModel.database.write { db in
            var feed = Feed(
                id: nil,
                title: "Test Feed",
                feedURL: "https://example.com/test-feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                unreadCount: 0,
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw TestError.missingFeedID
            }

            var entryA = Entry(
                id: nil,
                feedId: feedId,
                guid: "a-\(UUID().uuidString)",
                url: "https://example.com/a",
                title: "Entry A",
                author: "tester",
                publishedAt: Date(),
                summary: "A",
                isRead: false,
                createdAt: Date()
            )
            try entryA.insert(db)
            guard let entryAId = entryA.id else {
                throw TestError.missingEntryID
            }

            var entryB = Entry(
                id: nil,
                feedId: feedId,
                guid: "b-\(UUID().uuidString)",
                url: "https://example.com/b",
                title: "Entry B",
                author: "tester",
                publishedAt: Date().addingTimeInterval(1),
                summary: "B",
                isRead: false,
                createdAt: Date().addingTimeInterval(1)
            )
            try entryB.insert(db)
            guard let entryBId = entryB.id else {
                throw TestError.missingEntryID
            }

            return (entryAId, entryBId)
        }
    }

    private func countSummaryTotal(_ appModel: AppModel) async throws -> Int {
        try await appModel.database.read { db in
            try AISummaryResult.fetchCount(db)
        }
    }

    private func countSummaryTaskRunTotal(_ appModel: AppModel) async throws -> Int {
        try await appModel.database.read { db in
            try AITaskRun
                .filter(Column("taskType") == AITaskType.summary.rawValue)
                .fetchCount(db)
        }
    }

    private func countSummarySlot(
        _ appModel: AppModel,
        entryId: Int64,
        targetLanguage: String,
        detailLevel: AISummaryDetailLevel
    ) async throws -> Int {
        try await appModel.database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM ai_summary_result
                WHERE entryId = ? AND targetLanguage = ? AND detailLevel = ?
                """,
                arguments: [entryId, targetLanguage, detailLevel.rawValue]
            ) ?? 0
        }
    }

    private func taskRunExists(_ appModel: AppModel, runId: Int64) async throws -> Bool {
        try await appModel.database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM ai_task_run WHERE id = ?)",
                arguments: [runId]
            ) ?? false
        }
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-summary-tests-\(UUID().uuidString).sqlite")
            .path
    }
}

private enum TestError: Error {
    case missingFeedID
    case missingEntryID
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func save(secret: String, for ref: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[ref] = secret
    }

    func readSecret(for ref: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let value = storage[ref] {
            return value
        }
        throw CredentialStoreError.itemNotFound
    }

    func deleteSecret(for ref: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: ref)
    }
}
