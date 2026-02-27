import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Translation Storage Persistence")
struct TranslationStoragePersistenceTests {
    @Test("Successful persistence replaces same-slot payload and deletes stale run")
    @MainActor
    func persistReplacesSlotPayload() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationPersistenceTestCredentialStore()
        )

        let entryId = try await seedEntry(using: appModel)
        let slotLanguage = "zh-cn"
        let slotHash = "slot-hash-a"
        let segmenterVersion = TranslationSegmentationContract.segmenterVersion

        let first = try await appModel.persistSuccessfulTranslationResult(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v1",
            targetLanguage: slotLanguage,
            sourceContentHash: slotHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: slotLanguage,
            segments: [
                TranslationPersistedSegmentInput(
                    sourceSegmentId: "seg_1_b",
                    orderIndex: 1,
                    sourceTextSnapshot: "B",
                    translatedText: "乙"
                ),
                TranslationPersistedSegmentInput(
                    sourceSegmentId: "seg_0_a",
                    orderIndex: 0,
                    sourceTextSnapshot: "A",
                    translatedText: "甲"
                )
            ],
            templateId: "translation.default",
            templateVersion: "v1",
            runtimeParameterSnapshot: ["concurrencyDegree": "3"],
            durationMs: 100
        )
        let firstRunID = first.run.id
        #expect(firstRunID != nil)

        let second = try await appModel.persistSuccessfulTranslationResult(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v1",
            targetLanguage: slotLanguage,
            sourceContentHash: slotHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: slotLanguage,
            segments: [
                TranslationPersistedSegmentInput(
                    sourceSegmentId: "seg_0_a",
                    orderIndex: 0,
                    sourceTextSnapshot: "A",
                    translatedText: "新甲"
                ),
                TranslationPersistedSegmentInput(
                    sourceSegmentId: "seg_1_b",
                    orderIndex: 1,
                    sourceTextSnapshot: "B",
                    translatedText: "新乙"
                )
            ],
            templateId: "translation.default",
            templateVersion: "v1",
            runtimeParameterSnapshot: ["concurrencyDegree": "3"],
            durationMs: 120
        )
        let secondRunID = second.run.id
        #expect(secondRunID != nil)
        #expect(secondRunID != firstRunID)

        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: "zh-Hans"
        )
        let loaded = try await appModel.loadTranslationRecord(slotKey: slotKey)
        #expect(loaded != nil)
        #expect(loaded?.run.id == secondRunID)
        #expect(loaded?.segments.map(\.orderIndex) == [0, 1])
        #expect(loaded?.segments.map(\.translatedText) == ["新甲", "新乙"])

        let oldRunStillExists = try await appModel.database.read { db in
            guard let firstRunID else { return false }
            return try AgentTaskRun.filter(Column("id") == firstRunID).fetchCount(db) > 0
        }
        #expect(oldRunStillExists == false)
    }

    @Test("Delete slot removes persisted translation payload")
    @MainActor
    func deleteSlotPayload() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationPersistenceTestCredentialStore()
        )

        let entryId = try await seedEntry(using: appModel)
        let targetLanguage = "zh-Hans"
        let sourceHash = "slot-delete-hash"
        let segmenterVersion = TranslationSegmentationContract.segmenterVersion

        _ = try await appModel.persistSuccessfulTranslationResult(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v1",
            targetLanguage: targetLanguage,
            sourceContentHash: sourceHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: targetLanguage,
            segments: [
                TranslationPersistedSegmentInput(
                    sourceSegmentId: "seg_0_a",
                    orderIndex: 0,
                    sourceTextSnapshot: "A",
                    translatedText: "甲"
                )
            ],
            templateId: "translation.default",
            templateVersion: "v1",
            runtimeParameterSnapshot: ["concurrencyDegree": "3"],
            durationMs: 88
        )

        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage
        )
        #expect(try await appModel.loadTranslationRecord(slotKey: slotKey) != nil)

        let deleted = try await appModel.deleteTranslationRecord(slotKey: slotKey)
        #expect(deleted == true)
        #expect(try await appModel.loadTranslationRecord(slotKey: slotKey) == nil)
    }

    @Test("Checkpoint start persists running row and can be discarded on terminal failure")
    @MainActor
    func checkpointStartAndDiscard() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationPersistenceTestCredentialStore()
        )

        let entryId = try await seedEntry(using: appModel)
        let targetLanguage = "zh-Hans"
        let sourceHash = "checkpoint-hash-a"
        let segmenterVersion = TranslationSegmentationContract.segmenterVersion

        let checkpointRunId = try await appModel.startTranslationRunForCheckpoint(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v3",
            targetLanguage: targetLanguage,
            sourceContentHash: sourceHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: targetLanguage,
            templateId: "translation.default",
            templateVersion: "v3",
            runtimeParameterSnapshot: ["checkpointPersistence": "true"],
            durationMs: nil
        )

        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage
        )
        let runningRecord = try await appModel.loadTranslationRecord(slotKey: slotKey)
        #expect(runningRecord != nil)
        #expect(runningRecord?.run.id == checkpointRunId)
        #expect(runningRecord?.run.status == .running)
        #expect(runningRecord?.result.runStatus == .running)
        #expect(runningRecord?.isCheckpointRunning == true)

        let discarded = try await appModel.discardRunningTranslationCheckpoint(taskRunId: checkpointRunId)
        #expect(discarded == true)
        #expect(try await appModel.loadTranslationRecord(slotKey: slotKey) == nil)
    }

    @Test("Checkpoint finalize reuses same run id and marks row succeeded")
    @MainActor
    func checkpointFinalizeReusesRunId() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationPersistenceTestCredentialStore()
        )

        let entryId = try await seedEntry(using: appModel)
        let targetLanguage = "zh-Hans"
        let sourceHash = "checkpoint-hash-b"
        let segmenterVersion = TranslationSegmentationContract.segmenterVersion

        let checkpointRunId = try await appModel.startTranslationRunForCheckpoint(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v3",
            targetLanguage: targetLanguage,
            sourceContentHash: sourceHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: targetLanguage,
            templateId: "translation.default",
            templateVersion: "v3",
            runtimeParameterSnapshot: ["checkpointPersistence": "true"],
            durationMs: nil
        )

        try await appModel.persistTranslationSegmentCheckpoint(
            taskRunId: checkpointRunId,
            segment: TranslationPersistedSegmentInput(
                sourceSegmentId: "seg_0_a",
                orderIndex: 0,
                sourceTextSnapshot: "A",
                translatedText: "甲"
            )
        )

        let finalized = try await appModel.persistSuccessfulTranslationResult(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v3",
            targetLanguage: targetLanguage,
            sourceContentHash: sourceHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: targetLanguage,
            segments: [
                TranslationPersistedSegmentInput(
                    sourceSegmentId: "seg_0_a",
                    orderIndex: 0,
                    sourceTextSnapshot: "A",
                    translatedText: "甲"
                ),
                TranslationPersistedSegmentInput(
                    sourceSegmentId: "seg_1_b",
                    orderIndex: 1,
                    sourceTextSnapshot: "B",
                    translatedText: "乙"
                )
            ],
            templateId: "translation.default",
            templateVersion: "v3",
            runtimeParameterSnapshot: ["checkpointFinalize": "true"],
            durationMs: 123,
            checkpointTaskRunId: checkpointRunId
        )

        #expect(finalized.run.id == checkpointRunId)
        #expect(finalized.run.status == .succeeded)
        #expect(finalized.result.runStatus == .succeeded)
        #expect(finalized.segments.map(\.translatedText) == ["甲", "乙"])

        let runCount = try await appModel.database.read { db in
            try AgentTaskRun.filter(Column("entryId") == entryId).fetchCount(db)
        }
        #expect(runCount == 1)
    }

    @Test("Load detects orphaned running checkpoint row")
    @MainActor
    func loadDetectsOrphanedCheckpointRow() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationPersistenceTestCredentialStore()
        )

        let entryId = try await seedEntry(using: appModel)
        let targetLanguage = "zh-Hans"
        let sourceHash = "checkpoint-hash-c"
        let segmenterVersion = TranslationSegmentationContract.segmenterVersion

        let checkpointRunId = try await appModel.startTranslationRunForCheckpoint(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v3",
            targetLanguage: targetLanguage,
            sourceContentHash: sourceHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: targetLanguage,
            templateId: "translation.default",
            templateVersion: "v3",
            runtimeParameterSnapshot: ["checkpointPersistence": "true"],
            durationMs: nil
        )

        try await appModel.persistTranslationSegmentCheckpoint(
            taskRunId: checkpointRunId,
            segment: TranslationPersistedSegmentInput(
                sourceSegmentId: "seg_0_a",
                orderIndex: 0,
                sourceTextSnapshot: "A",
                translatedText: "甲"
            )
        )

        try await appModel.database.write { db in
            _ = try AgentTaskRun
                .filter(Column("id") == checkpointRunId)
                .updateAll(
                    db,
                    [
                        Column("status").set(to: AgentTaskRunStatus.failed.rawValue),
                        Column("updatedAt").set(to: Date())
                    ]
                )
        }

        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage
        )
        let loaded = try await appModel.loadTranslationRecord(slotKey: slotKey)
        #expect(loaded != nil)
        #expect(loaded?.result.runStatus == .running)
        #expect(loaded?.isCheckpointRunning == true)
        #expect(loaded?.isCheckpointOrphaned == true)
    }

    @Test("Starting a checkpoint run replaces orphaned running row in same slot")
    @MainActor
    func checkpointStartReplacesOrphanedRowInSameSlot() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationPersistenceTestCredentialStore()
        )

        let entryId = try await seedEntry(using: appModel)
        let targetLanguage = "zh-Hans"
        let sourceHash = "checkpoint-hash-d"
        let segmenterVersion = TranslationSegmentationContract.segmenterVersion

        let oldRunId = try await appModel.startTranslationRunForCheckpoint(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v3",
            targetLanguage: targetLanguage,
            sourceContentHash: sourceHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: targetLanguage,
            templateId: "translation.default",
            templateVersion: "v3",
            runtimeParameterSnapshot: ["checkpointPersistence": "true"],
            durationMs: nil
        )
        try await appModel.persistTranslationSegmentCheckpoint(
            taskRunId: oldRunId,
            segment: TranslationPersistedSegmentInput(
                sourceSegmentId: "seg_0_a",
                orderIndex: 0,
                sourceTextSnapshot: "A",
                translatedText: "旧甲"
            )
        )

        try await appModel.database.write { db in
            _ = try AgentTaskRun
                .filter(Column("id") == oldRunId)
                .updateAll(
                    db,
                    [
                        Column("status").set(to: AgentTaskRunStatus.failed.rawValue),
                        Column("updatedAt").set(to: Date())
                    ]
                )
        }

        let newRunId = try await appModel.startTranslationRunForCheckpoint(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v3",
            targetLanguage: targetLanguage,
            sourceContentHash: sourceHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: targetLanguage,
            templateId: "translation.default",
            templateVersion: "v3",
            runtimeParameterSnapshot: ["checkpointPersistence": "true"],
            durationMs: nil
        )
        #expect(newRunId != oldRunId)

        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage
        )
        let loaded = try await appModel.loadTranslationRecord(slotKey: slotKey)
        #expect(loaded != nil)
        #expect(loaded?.run.id == newRunId)
        #expect(loaded?.run.status == .running)
        #expect(loaded?.result.runStatus == .running)
        #expect(loaded?.segments.isEmpty == true)
        #expect(loaded?.isCheckpointOrphaned == false)

        let oldRunStillExists = try await appModel.database.read { db in
            try AgentTaskRun
                .filter(Column("id") == oldRunId)
                .fetchCount(db) > 0
        }
        #expect(oldRunStillExists == false)
    }

    @Test("Checkpoint finalize stores provider and model ids when they are valid")
    @MainActor
    func checkpointFinalizeStoresProviderAndModelIDs() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationPersistenceTestCredentialStore()
        )

        let entryId = try await seedEntry(using: appModel)
        let (providerId, modelId) = try await seedProviderAndModel(using: appModel)
        let targetLanguage = "zh-Hans"
        let sourceHash = "checkpoint-hash-e"
        let segmenterVersion = TranslationSegmentationContract.segmenterVersion

        let checkpointRunId = try await appModel.startTranslationRunForCheckpoint(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: nil,
            modelProfileId: nil,
            promptVersion: "translation.default@v3",
            targetLanguage: targetLanguage,
            sourceContentHash: sourceHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: targetLanguage,
            templateId: "translation.default",
            templateVersion: "v3",
            runtimeParameterSnapshot: ["checkpointPersistence": "true"],
            durationMs: nil
        )

        try await appModel.persistTranslationSegmentCheckpoint(
            taskRunId: checkpointRunId,
            segment: TranslationPersistedSegmentInput(
                sourceSegmentId: "seg_0_a",
                orderIndex: 0,
                sourceTextSnapshot: "A",
                translatedText: "甲"
            )
        )

        let finalized = try await appModel.persistSuccessfulTranslationResult(
            entryId: entryId,
            agentProfileId: nil,
            providerProfileId: providerId,
            modelProfileId: modelId,
            promptVersion: "translation.default@v3",
            targetLanguage: targetLanguage,
            sourceContentHash: sourceHash,
            segmenterVersion: segmenterVersion,
            outputLanguage: targetLanguage,
            segments: [
                TranslationPersistedSegmentInput(
                    sourceSegmentId: "seg_0_a",
                    orderIndex: 0,
                    sourceTextSnapshot: "A",
                    translatedText: "甲"
                )
            ],
            templateId: "translation.default",
            templateVersion: "v3",
            runtimeParameterSnapshot: ["checkpointFinalize": "withRouteIDs"],
            durationMs: 77,
            checkpointTaskRunId: checkpointRunId
        )

        #expect(finalized.run.id == checkpointRunId)
        #expect(finalized.run.providerProfileId == providerId)
        #expect(finalized.run.modelProfileId == modelId)

        let persistedRun = try await appModel.database.read { db in
            try AgentTaskRun
                .filter(Column("id") == checkpointRunId)
                .fetchOne(db)
        }
        #expect(persistedRun?.providerProfileId == providerId)
        #expect(persistedRun?.modelProfileId == modelId)
    }

    private func seedEntry(using appModel: AppModel) async throws -> Int64 {
        try await appModel.database.write { db in
            var feed = Feed(
                id: nil,
                title: "T",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                unreadCount: 0,
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw PersistenceTestError.missingFeedID
            }

            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "guid-\(UUID().uuidString)",
                url: "https://example.com/item",
                title: "Title",
                author: "A",
                publishedAt: Date(),
                summary: "S",
                isRead: false,
                createdAt: Date()
            )
            try entry.insert(db)
            guard let entryId = entry.id else {
                throw PersistenceTestError.missingEntryID
            }

            return entryId
        }
    }

    private func seedProviderAndModel(using appModel: AppModel) async throws -> (Int64, Int64) {
        try await appModel.database.write { db in
            let now = Date()
            var provider = AgentProviderProfile(
                id: nil,
                name: "Provider-\(UUID().uuidString)",
                baseURL: "http://localhost:5810/v1",
                apiKeyRef: "key-\(UUID().uuidString)",
                testModel: "qwen3",
                isDefault: false,
                isEnabled: true,
                isArchived: false,
                archivedAt: nil,
                createdAt: now,
                updatedAt: now
            )
            try provider.insert(db)
            guard let providerId = provider.id else {
                throw PersistenceTestError.missingProviderID
            }

            var model = AgentModelProfile(
                id: nil,
                providerProfileId: providerId,
                name: "Model-\(UUID().uuidString)",
                modelName: "qwen3",
                temperature: nil,
                topP: nil,
                maxTokens: nil,
                isStreaming: true,
                supportsTagging: false,
                supportsSummary: false,
                supportsTranslation: true,
                isDefault: false,
                isEnabled: true,
                isArchived: false,
                archivedAt: nil,
                lastTestedAt: nil,
                createdAt: now,
                updatedAt: now
            )
            try model.insert(db)
            guard let modelId = model.id else {
                throw PersistenceTestError.missingModelID
            }

            return (providerId, modelId)
        }
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-translation-persist-tests-\(UUID().uuidString).sqlite")
            .path
    }
}

private enum PersistenceTestError: Error {
    case missingFeedID
    case missingEntryID
    case missingProviderID
    case missingModelID
}

private final class TranslationPersistenceTestCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    func save(secret: String, for ref: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[ref] = secret
    }

    func readSecret(for ref: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let secret = storage[ref] else {
            throw CredentialStoreError.itemNotFound
        }
        return secret
    }

    func deleteSecret(for ref: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: ref)
    }
}
