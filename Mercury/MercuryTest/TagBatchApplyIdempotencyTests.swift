import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tag Batch Apply")
struct TagBatchApplyIdempotencyTests {
    @Test("Apply uses idempotent entry_tag writes and finalizes run")
    @MainActor
    func applyIdempotentAndFinalize() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagBatchTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database
            let store = TagBatchStore(db: database)

            let setup = try await seedBatchApplyFixture(database: database, store: store)

            // Pre-insert one assignment to verify apply remains idempotent.
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO entry_tag (entryId, tagId, source, confidence)
                    VALUES (?, ?, ?, NULL)
                    """,
                    arguments: [setup.entryIds[0], setup.swiftTagId, "manual"]
                )
            }

            try await store.updateReviewDecision(
                runId: setup.runId,
                normalizedName: "ai",
                decision: .keep
            )

            try await appModel.applyTaggingBatchRun(runId: setup.runId) { _ in }

            let run = try #require(await store.loadRun(id: setup.runId))
            #expect(run.status == .done)
            #expect(run.createdTagCount == 1)
            #expect(run.insertedEntryTagCount == 3)
            #expect(run.keptProposalCount == 1)
            #expect(run.discardedProposalCount == 0)

            try await database.read { db in
                let entryTagCount = try EntryTag.fetchCount(db)
                #expect(entryTagCount == 4)

                let aiTag = try Tag
                    .filter(Column("normalizedName") == "ai")
                    .fetchOne(db)
                let resolvedAITag = try #require(aiTag)
                #expect(resolvedAITag.usageCount == 1)
                #expect(resolvedAITag.isProvisional == true)

                let swiftTag = try Tag.filter(Column("id") == setup.swiftTagId).fetchOne(db)
                let resolvedSwiftTag = try #require(swiftTag)
                #expect(resolvedSwiftTag.usageCount == 3)
                #expect(resolvedSwiftTag.isProvisional == false)

                let persistedBatchEntries = try TagBatchEntry
                    .filter(Column("runId") == setup.runId)
                    .fetchAll(db)
                let stagingAssignmentCount = try TagBatchAssignmentStaging.filter(Column("runId") == setup.runId).fetchCount(db)
                let reviewCount = try TagBatchNewTagReview.filter(Column("runId") == setup.runId).fetchCount(db)
                let checkpointCount = try TagBatchApplyCheckpoint.filter(Column("runId") == setup.runId).fetchCount(db)

                #expect(persistedBatchEntries.count == setup.entryIds.count)
                #expect(persistedBatchEntries.allSatisfy { $0.lifecycleState == .applied })
                #expect(stagingAssignmentCount == 0)
                #expect(reviewCount == 0)
                #expect(checkpointCount == 0)
            }
        }
    }

    private func seedBatchApplyFixture(
        database: DatabaseManager,
        store: TagBatchStore
    ) async throws -> (runId: Int64, entryIds: [Int64], swiftTagId: Int64) {
        let seeded = try await database.write { db -> (entryIds: [Int64], swiftTagId: Int64) in
            var feed = Feed(
                id: nil,
                title: "Feed",
                feedURL: "https://example.com/feed",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            let feedId = try #require(feed.id)

            var entryIds: [Int64] = []
            for index in 1...3 {
                var entry = Entry(
                    id: nil,
                    feedId: feedId,
                    guid: "entry-\(index)",
                    url: "https://example.com/\(index)",
                    title: "Entry \(index)",
                    author: nil,
                    publishedAt: Date(),
                    summary: "Summary \(index)",
                    isRead: false,
                    isStarred: false,
                    createdAt: Date()
                )
                try entry.insert(db)
                entryIds.append(try #require(entry.id))
            }

            var swiftTag = Tag(
                id: nil,
                name: "Swift",
                normalizedName: "swift",
                isProvisional: false,
                usageCount: 0
            )
            try swiftTag.insert(db)
            let swiftTagId = try #require(swiftTag.id)

            return (entryIds: entryIds, swiftTagId: swiftTagId)
        }

        let runId = try await store.createRun(
            scopeLabel: "all",
            skipAlreadyApplied: false,
            skipAlreadyTagged: false,
            concurrency: 1,
            totalSelectedEntries: seeded.entryIds.count,
            totalPlannedEntries: seeded.entryIds.count
        )
        try await store.updateRunStatus(runId: runId, status: .review)

        for entryId in seeded.entryIds {
            try await store.upsertBatchEntry(
                TagBatchEntry(
                    id: nil,
                    runId: runId,
                    entryId: entryId,
                    lifecycleState: .stagedReady,
                    attempts: 1,
                    providerProfileId: nil,
                    modelProfileId: nil,
                    promptTokens: nil,
                    completionTokens: nil,
                    durationMs: nil,
                    rawResponse: nil,
                    errorMessage: nil,
                    createdAt: Date(),
                    updatedAt: Date()
                )
            )

            try await store.upsertAssignment(
                TagBatchAssignmentStaging(
                    id: nil,
                    runId: runId,
                    entryId: entryId,
                    normalizedName: "swift",
                    displayName: "Swift",
                    resolvedTagId: seeded.swiftTagId,
                    assignmentKind: .matched,
                    createdAt: Date(),
                    updatedAt: Date()
                )
            )
        }

        // Add one new proposal that requires review keep/discard decision.
        try await store.upsertAssignment(
            TagBatchAssignmentStaging(
                id: nil,
                runId: runId,
                entryId: seeded.entryIds[2],
                normalizedName: "ai",
                displayName: "AI",
                resolvedTagId: nil,
                assignmentKind: .newProposal,
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        try await store.rebuildReviewRowsFromAssignments(runId: runId)

        return (runId: runId, entryIds: seeded.entryIds, swiftTagId: seeded.swiftTagId)
    }
}

private final class TagBatchTestCredentialStore: CredentialStore, @unchecked Sendable {
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
