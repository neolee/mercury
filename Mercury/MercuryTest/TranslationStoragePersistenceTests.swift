import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Translation Storage Persistence")
@MainActor
struct TranslationStoragePersistenceTests {
    @Test("Successful persistence replaces same-slot payload and deletes stale run")
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
            runtimeParameterSnapshot: ["strategy": "A"],
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
            runtimeParameterSnapshot: ["strategy": "A"],
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
            runtimeParameterSnapshot: ["strategy": "A"],
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

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-translation-persist-tests-\(UUID().uuidString).sqlite")
            .path
    }
}

private enum PersistenceTestError: Error {
    case missingFeedID
    case missingEntryID
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
