import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Translation Storage Query")
@MainActor
struct TranslationStorageQueryTests {
    @Test("Slot lookup requires exact key and returns ordered segments")
    func slotLookupExactMatchAndOrdering() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationStorageTestCredentialStore()
        )

        let entryId = try await seedEntry(using: appModel)
        let now = Date()

        try await appModel.database.write { db in
            var run1 = AgentTaskRun(
                id: nil,
                entryId: entryId,
                taskType: .translation,
                status: .succeeded,
                agentProfileId: nil,
                providerProfileId: nil,
                modelProfileId: nil,
                promptVersion: "translation-v1",
                targetLanguage: "zh-Hans",
                templateId: "translation.default",
                templateVersion: "v1",
                runtimeParameterSnapshot: nil,
                durationMs: 120,
                createdAt: now,
                updatedAt: now
            )
            try run1.insert(db)
            guard let run1ID = run1.id else {
                throw TestError.missingRunID
            }

            var result1 = TranslationResult(
                taskRunId: run1ID,
                entryId: entryId,
                targetLanguage: "zh-Hans",
                sourceContentHash: "hash-a",
                segmenterVersion: "v1",
                outputLanguage: "zh-Hans",
                createdAt: now,
                updatedAt: now
            )
            try result1.insert(db)

            var seg1 = TranslationSegment(
                taskRunId: run1ID,
                sourceSegmentId: "seg_1_x",
                orderIndex: 1,
                sourceTextSnapshot: "B",
                translatedText: "乙",
                createdAt: now,
                updatedAt: now
            )
            try seg1.insert(db)
            var seg0 = TranslationSegment(
                taskRunId: run1ID,
                sourceSegmentId: "seg_0_x",
                orderIndex: 0,
                sourceTextSnapshot: "A",
                translatedText: "甲",
                createdAt: now,
                updatedAt: now
            )
            try seg0.insert(db)

            var run2 = AgentTaskRun(
                id: nil,
                entryId: entryId,
                taskType: .translation,
                status: .succeeded,
                agentProfileId: nil,
                providerProfileId: nil,
                modelProfileId: nil,
                promptVersion: "translation-v1",
                targetLanguage: "zh-Hans",
                templateId: "translation.default",
                templateVersion: "v1",
                runtimeParameterSnapshot: nil,
                durationMs: 80,
                createdAt: now,
                updatedAt: now
            )
            try run2.insert(db)
            guard let run2ID = run2.id else {
                throw TestError.missingRunID
            }

            var result2 = TranslationResult(
                taskRunId: run2ID,
                entryId: entryId,
                targetLanguage: "zh-Hans",
                sourceContentHash: "hash-b",
                segmenterVersion: "v1",
                outputLanguage: "zh-Hans",
                createdAt: now,
                updatedAt: now
            )
            try result2.insert(db)
        }

        let matchedKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: "zh-cn",
            sourceContentHash: "hash-a",
            segmenterVersion: "v1"
        )
        let matched = try await appModel.loadTranslationRecord(slotKey: matchedKey)

        #expect(matched != nil)
        let matchedSegments = matched?.segments ?? []
        #expect(matched?.result.sourceContentHash == "hash-a")
        #expect(matchedSegments.map(\.orderIndex) == [0, 1])
        #expect(matchedSegments.map(\.translatedText) == ["甲", "乙"])

        let missHash = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: "zh-Hans",
            sourceContentHash: "hash-c",
            segmenterVersion: "v1"
        )
        #expect(try await appModel.loadTranslationRecord(slotKey: missHash) == nil)

        let missVersion = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: "zh-Hans",
            sourceContentHash: "hash-a",
            segmenterVersion: "v2"
        )
        #expect(try await appModel.loadTranslationRecord(slotKey: missVersion) == nil)
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
                throw TestError.missingFeedID
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
                throw TestError.missingEntryID
            }

            return entryId
        }
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-translation-slot-tests-\(UUID().uuidString).sqlite")
            .path
    }
}

private enum TestError: Error {
    case missingFeedID
    case missingEntryID
    case missingRunID
}

private final class TranslationStorageTestCredentialStore: CredentialStore, @unchecked Sendable {
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
