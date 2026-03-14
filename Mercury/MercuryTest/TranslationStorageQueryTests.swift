import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Translation Storage Query")
struct TranslationStorageQueryTests {
    @Test("Slot lookup requires exact key and returns ordered segments")
    @MainActor
    func slotLookupExactMatchAndOrdering() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TranslationStorageTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
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
                    runStatus: .succeeded,
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
            }

            let matchedKey = appModel.makeTranslationSlotKey(
                entryId: entryId,
                targetLanguage: "zh-cn"
            )
            let matchedSnapshot = makeSnapshot(
                entryId: entryId,
                sourceContentHash: "hash-a",
                segmenterVersion: "v1"
            )
            let matched = try await appModel.loadCompatibleTranslationRecord(
                slotKey: matchedKey,
                sourceSnapshot: matchedSnapshot
            )

            #expect(matched != nil)
            let matchedSegments = matched?.segments ?? []
            #expect(matched?.result.sourceContentHash == "hash-a")
            #expect(matchedSegments.map(\.orderIndex) == [0, 1])
            #expect(matchedSegments.map(\.translatedText) == ["甲", "乙"])

            let missEntry = appModel.makeTranslationSlotKey(
                entryId: entryId + 999,
                targetLanguage: "zh-Hans"
            )
            #expect(
                try await appModel.loadCompatibleTranslationRecord(
                    slotKey: missEntry,
                    sourceSnapshot: matchedSnapshot
                ) == nil
            )

            let missLanguage = appModel.makeTranslationSlotKey(
                entryId: entryId,
                targetLanguage: "ja"
            )
            #expect(
                try await appModel.loadCompatibleTranslationRecord(
                    slotKey: missLanguage,
                    sourceSnapshot: matchedSnapshot
                ) == nil
            )
        }
    }

    private func makeSnapshot(
        entryId: Int64,
        sourceContentHash: String,
        segmenterVersion: String
    ) -> TranslationSourceSegmentsSnapshot {
        TranslationSourceSegmentsSnapshot(
            entryId: entryId,
            sourceContentHash: sourceContentHash,
            segmenterVersion: segmenterVersion,
            segments: []
        )
    }

    private func seedEntry(using appModel: AppModel) async throws -> Int64 {
        try await appModel.database.write { db in
            var feed = Feed(
                id: nil,
                title: "T",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
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
