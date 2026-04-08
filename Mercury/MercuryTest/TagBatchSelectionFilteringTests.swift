import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tag Batch Selection Filtering")
struct TagBatchSelectionFilteringTests {
    @Test("Estimate and fetch apply both skip filters consistently before start")
    @MainActor
    func estimateAndFetchRespectSkipOptions() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagBatchSelectionTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database
            let seeded = try await seedSelectionFixture(database: database)

            let noSkipCount = try await appModel.estimateTagBatchEntryCount(
                scope: .allEntries,
                skipAlreadyApplied: false,
                skipAlreadyTagged: false
            )
            let noSkipIDs = try await appModel.fetchTagBatchEntryIDsForExecution(
                scope: .allEntries,
                skipAlreadyApplied: false,
                skipAlreadyTagged: false
            )
            #expect(noSkipCount == 4)
            #expect(noSkipIDs == seeded.allEntryIDs)

            let skipTaggedCount = try await appModel.estimateTagBatchEntryCount(
                scope: .allEntries,
                skipAlreadyApplied: false,
                skipAlreadyTagged: true
            )
            let skipTaggedIDs = try await appModel.fetchTagBatchEntryIDsForExecution(
                scope: .allEntries,
                skipAlreadyApplied: false,
                skipAlreadyTagged: true
            )
            #expect(skipTaggedCount == 2)
            #expect(skipTaggedIDs == [seeded.untaggedEntryId, seeded.appliedOnlyEntryId])

            let skipAppliedCount = try await appModel.estimateTagBatchEntryCount(
                scope: .allEntries,
                skipAlreadyApplied: true,
                skipAlreadyTagged: false
            )
            let skipAppliedIDs = try await appModel.fetchTagBatchEntryIDsForExecution(
                scope: .allEntries,
                skipAlreadyApplied: true,
                skipAlreadyTagged: false
            )
            #expect(skipAppliedCount == 2)
            #expect(skipAppliedIDs == [seeded.untaggedEntryId, seeded.taggedOnlyEntryId])

            let skipBothCount = try await appModel.estimateTagBatchEntryCount(
                scope: .allEntries,
                skipAlreadyApplied: true,
                skipAlreadyTagged: true
            )
            let skipBothIDs = try await appModel.fetchTagBatchEntryIDsForExecution(
                scope: .allEntries,
                skipAlreadyApplied: true,
                skipAlreadyTagged: true
            )
            #expect(skipBothCount == 1)
            #expect(skipBothIDs == [seeded.untaggedEntryId])
        }
    }

    @Test("Estimate and fetch exclude tombstoned entries")
    @MainActor
    func estimateAndFetchExcludeTombstonedEntries() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagBatchSelectionTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database
            let seeded = try await seedSelectionFixture(database: database)

            try await database.write { db in
                _ = try Entry
                    .filter(Column("id") == seeded.appliedOnlyEntryId)
                    .updateAll(db, Column("isDeleted").set(to: true))
            }

            let count = try await appModel.estimateTagBatchEntryCount(
                scope: .allEntries,
                skipAlreadyApplied: false,
                skipAlreadyTagged: false
            )
            let ids = try await appModel.fetchTagBatchEntryIDsForExecution(
                scope: .allEntries,
                skipAlreadyApplied: false,
                skipAlreadyTagged: false
            )

            #expect(count == 3)
            #expect(ids == [
                seeded.untaggedEntryId,
                seeded.taggedOnlyEntryId,
                seeded.taggedAndAppliedEntryId
            ])
        }
    }

    private func seedSelectionFixture(
        database: DatabaseManager
    ) async throws -> (
        allEntryIDs: [Int64],
        untaggedEntryId: Int64,
        taggedOnlyEntryId: Int64,
        appliedOnlyEntryId: Int64,
        taggedAndAppliedEntryId: Int64
    ) {
        try await database.write { db in
            let now = Date()

            var feed = Feed(
                id: nil,
                title: "Feed",
                feedURL: "https://example.com/feed",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: now
            )
            try feed.insert(db)
            let feedId = try #require(feed.id)

            func makeEntry(idSuffix: String, title: String, daysAgo: TimeInterval) throws -> Int64 {
                var entry = Entry(
                    id: nil,
                    feedId: feedId,
                    guid: "entry-\(idSuffix)",
                    url: "https://example.com/\(idSuffix)",
                    title: title,
                    author: nil,
                    publishedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60),
                    summary: "Summary \(idSuffix)",
                    isRead: false,
                    isStarred: false,
                    createdAt: now
                )
                try entry.insert(db)
                return try #require(entry.id)
            }

            let untaggedEntryId = try makeEntry(idSuffix: "untagged", title: "Untagged", daysAgo: 0)
            let taggedOnlyEntryId = try makeEntry(idSuffix: "tagged", title: "Tagged Only", daysAgo: 1)
            let appliedOnlyEntryId = try makeEntry(idSuffix: "applied", title: "Applied Only", daysAgo: 2)
            let taggedAndAppliedEntryId = try makeEntry(idSuffix: "both", title: "Tagged And Applied", daysAgo: 3)

            var tag = Tag(
                id: nil,
                name: "Swift",
                normalizedName: "swift",
                isProvisional: false,
                usageCount: 2
            )
            try tag.insert(db)
            let tagId = try #require(tag.id)

            try db.execute(
                sql: """
                INSERT INTO entry_tag (entryId, tagId, source, confidence)
                VALUES (?, ?, ?, NULL),
                       (?, ?, ?, NULL)
                """,
                arguments: [
                    taggedOnlyEntryId, tagId, "manual",
                    taggedAndAppliedEntryId, tagId, "manual"
                ]
            )

            var run = TagBatchRun(
                id: nil,
                status: .done,
                scopeLabel: TagBatchSelectionScope.allEntries.rawValue,
                skipAlreadyApplied: true,
                skipAlreadyTagged: true,
                concurrency: 3,
                totalSelectedEntries: 2,
                totalPlannedEntries: 2,
                processedEntries: 2,
                succeededEntries: 2,
                failedEntries: 0,
                keptProposalCount: 0,
                discardedProposalCount: 0,
                insertedEntryTagCount: 0,
                createdTagCount: 0,
                startedAt: now,
                completedAt: now,
                createdAt: now,
                updatedAt: now
            )
            try run.insert(db)
            let runId = try #require(run.id)

            for entryId in [appliedOnlyEntryId, taggedAndAppliedEntryId] {
                var batchEntry = TagBatchEntry(
                    id: nil,
                    runId: runId,
                    entryId: entryId,
                    lifecycleState: .applied,
                    attempts: 1,
                    providerProfileId: nil,
                    modelProfileId: nil,
                    promptTokens: nil,
                    completionTokens: nil,
                    durationMs: nil,
                    rawResponse: nil,
                    errorMessage: nil,
                    createdAt: now,
                    updatedAt: now
                )
                try batchEntry.insert(db)
            }

            return (
                allEntryIDs: [untaggedEntryId, taggedOnlyEntryId, appliedOnlyEntryId, taggedAndAppliedEntryId],
                untaggedEntryId: untaggedEntryId,
                taggedOnlyEntryId: taggedOnlyEntryId,
                appliedOnlyEntryId: appliedOnlyEntryId,
                taggedAndAppliedEntryId: taggedAndAppliedEntryId
            )
        }
    }
}

private final class TagBatchSelectionTestCredentialStore: CredentialStore, @unchecked Sendable {
    func save(secret: String, for ref: String) throws {
    }

    func readSecret(for ref: String) throws -> String {
        throw CredentialStoreError.itemNotFound
    }

    func deleteSecret(for ref: String) throws {
    }
}
