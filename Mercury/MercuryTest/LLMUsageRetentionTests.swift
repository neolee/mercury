import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("LLM Usage Retention")
struct LLMUsageRetentionTests {
    @Test("Retention policy removes only expired usage rows")
    @MainActor
    func retentionPolicyRemovesExpiredRows() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: InMemoryCredentialStoreForUsageRetentionTests()
        )

        let entryId = try await seedEntry(using: appModel.database)
        let now = Date()
        let referenceDate = now.addingTimeInterval(40 * 24 * 60 * 60)

        try await insertUsageRow(
            database: appModel.database,
            entryId: entryId,
            createdAt: now.addingTimeInterval(-5 * 24 * 60 * 60)
        )

        try await insertUsageRow(
            database: appModel.database,
            entryId: entryId,
            createdAt: now.addingTimeInterval(20 * 24 * 60 * 60)
        )

        let removedCount = try await appModel.purgeExpiredLLMUsageEvents(
            policy: .oneMonth,
            referenceDate: referenceDate
        )
        #expect(removedCount == 1)

        let remainingCount = try await appModel.database.read { db in
            try LLMUsageEvent.fetchCount(db)
        }
        #expect(remainingCount == 1)
    }

    @Test("Manual clear removes usage rows only")
    @MainActor
    func manualClearRemovesUsageRowsOnly() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: InMemoryCredentialStoreForUsageRetentionTests()
        )

        let entryId = try await seedEntry(using: appModel.database)

        let runID = try await appModel.database.write { db in
            var run = AgentTaskRun(
                id: nil,
                entryId: entryId,
                taskType: .summary,
                status: .succeeded,
                agentProfileId: nil,
                providerProfileId: nil,
                modelProfileId: nil,
                promptVersion: "summary-v1",
                targetLanguage: "en",
                templateId: "summary.default",
                templateVersion: "v1",
                runtimeParameterSnapshot: "{}",
                durationMs: 10,
                createdAt: Date(),
                updatedAt: Date()
            )
            try run.insert(db)
            guard let runID = run.id else {
                throw LLMUsageRetentionTestError.missingTaskRunID
            }
            return runID
        }

        try await insertUsageRow(database: appModel.database, entryId: entryId, createdAt: Date(), taskRunId: runID)

        let removedCount = try await appModel.clearLLMUsageEvents()
        #expect(removedCount == 1)

        let (usageCount, runCount) = try await appModel.database.read { db in
            let usageCount = try LLMUsageEvent.fetchCount(db)
            let runCount = try AgentTaskRun.fetchCount(db)
            return (usageCount, runCount)
        }

        #expect(usageCount == 0)
        #expect(runCount == 1)
    }

    @Test("Startup cleanup runs only when startup gate is ready")
    @MainActor
    func startupCleanupRequiresReadyGate() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: InMemoryCredentialStoreForUsageRetentionTests()
        )

        let entryId = try await seedEntry(using: appModel.database)
        let now = Date()
        let referenceDate = now.addingTimeInterval(40 * 24 * 60 * 60)
        let oldDate = now.addingTimeInterval(-5 * 24 * 60 * 60)
        try await insertUsageRow(database: appModel.database, entryId: entryId, createdAt: oldDate)

        appModel.startupGateState = .migratingDatabase
        let skippedRemovedCount = await appModel.runStartupLLMUsageRetentionCleanupIfReady(
            policy: .oneMonth,
            referenceDate: referenceDate
        )
        #expect(skippedRemovedCount == 0)

        let countAfterSkippedRun = try await appModel.database.read { db in
            try LLMUsageEvent.fetchCount(db)
        }
        #expect(countAfterSkippedRun == 1)

        appModel.startupGateState = .ready
        let removedCount = await appModel.runStartupLLMUsageRetentionCleanupIfReady(
            policy: .oneMonth,
            referenceDate: referenceDate
        )
        #expect(removedCount == 1)

        let countAfterReadyRun = try await appModel.database.read { db in
            try LLMUsageEvent.fetchCount(db)
        }
        #expect(countAfterReadyRun == 0)
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-usage-retention-tests-\(UUID().uuidString).sqlite")
            .path
    }

    private func seedEntry(using database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "Usage Retention Test Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                unreadCount: 0,
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw LLMUsageRetentionTestError.missingFeedID
            }

            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "usage-retention-guid-\(UUID().uuidString)",
                url: "https://example.com/item",
                title: "Usage Retention Entry",
                author: "tester",
                publishedAt: Date(),
                summary: "Summary",
                isRead: false,
                createdAt: Date()
            )
            try entry.insert(db)
            guard let entryId = entry.id else {
                throw LLMUsageRetentionTestError.missingEntryID
            }
            return entryId
        }
    }

    private func insertUsageRow(
        database: DatabaseManager,
        entryId: Int64,
        createdAt: Date,
        taskRunId: Int64? = nil
    ) async throws {
        try await database.write { db in
            var row = LLMUsageEvent(
                id: nil,
                taskRunId: taskRunId,
                entryId: entryId,
                taskType: .summary,
                providerProfileId: nil,
                modelProfileId: nil,
                providerBaseURLSnapshot: "https://example.com/v1",
                providerResolvedURLSnapshot: "https://example.com/v1/chat/completions",
                providerResolvedHostSnapshot: "example.com",
                providerResolvedPathSnapshot: "/v1/chat/completions",
                providerNameSnapshot: "Provider",
                modelNameSnapshot: "model",
                requestPhase: .normal,
                requestStatus: .succeeded,
                promptTokens: 10,
                completionTokens: 20,
                totalTokens: 30,
                usageAvailability: .actual,
                startedAt: createdAt,
                finishedAt: createdAt,
                createdAt: createdAt
            )
            try row.insert(db)
        }
    }
}

private enum LLMUsageRetentionTestError: Error {
    case missingFeedID
    case missingEntryID
    case missingTaskRunID
}

private final class InMemoryCredentialStoreForUsageRetentionTests: CredentialStore, @unchecked Sendable {
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
