import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Entry Delete Use Case")
struct EntryDeleteUseCaseTests {
    @Test("Delete tombstones the entry, clears derived rows, retains usage events, and refreshes tag usage")
    @MainActor
    func deleteEntryCleansDerivedRowsAndRetainsUsageEvents() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let useCase = EntryDeleteUseCase(database: database)
            let seeded = try await seedDeletionFixture(database: database)

            let didDelete = try await useCase.deleteEntry(entryId: seeded.deletedEntryId)
            #expect(didDelete == true)

            try await database.read { db in
                let deletedEntry = try #require(try Entry.fetchOne(db, key: seeded.deletedEntryId))
                #expect(deletedEntry.isDeleted == true)

                #expect(try Content.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) == 0)
                #expect(try ContentHTMLCache.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) == 0)
                #expect(try EntryNote.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) == 0)
                #expect(try EntryTag.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) == 0)
                #expect(try TagBatchEntry.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) == 0)
                #expect(try TagBatchAssignmentStaging.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) == 0)
                #expect(try AgentTaskRun.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) == 0)
                #expect(try SummaryResult.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) == 0)
                #expect(try TranslationResult.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) == 0)
                #expect(try TranslationSegment.fetchCount(db) == 0)

                let retainedUsageEvent = try #require(
                    try LLMUsageEvent
                        .filter(Column("id") == seeded.usageEventId)
                        .fetchOne(db)
                )
                #expect(retainedUsageEvent.entryId == seeded.deletedEntryId)
                #expect(retainedUsageEvent.taskRunId == nil)

                let sharedTag = try #require(try Tag.fetchOne(db, key: seeded.sharedTagId))
                #expect(sharedTag.usageCount == 1)
                #expect(sharedTag.isProvisional == true)

                let deletedOnlyTag = try #require(try Tag.fetchOne(db, key: seeded.deletedOnlyTagId))
                #expect(deletedOnlyTag.usageCount == 0)
                #expect(deletedOnlyTag.isProvisional == true)
            }
        }
    }

    @Test("Delete is blocked when the entry participates in an active batch lifecycle")
    @MainActor
    func deleteIsBlockedByActiveBatchLifecycle() async throws {
        for status in TagBatchRunStatus.activeLifecycleStatuses {
            try await InMemoryDatabaseFixture.withFixture { fixture in
                let database = fixture.database
                let useCase = EntryDeleteUseCase(database: database)
                let seeded = try await seedDeletionFixture(database: database, activeBatchStatus: status)

                await #expect(throws: EntryDeleteError.blockedByActiveTagBatch) {
                    try await useCase.deleteEntry(entryId: seeded.deletedEntryId)
                }

                try await database.read { db in
                    let entry = try #require(try Entry.fetchOne(db, key: seeded.deletedEntryId))
                    #expect(entry.isDeleted == false)
                    #expect(try AgentTaskRun.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) > 0)
                    #expect(try EntryTag.filter(Column("entryId") == seeded.deletedEntryId).fetchCount(db) > 0)
                }
            }
        }
    }

    @Test("Delete returns false for missing or already deleted entries")
    @MainActor
    func deleteMissingOrAlreadyDeletedEntryIsNoOp() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let useCase = EntryDeleteUseCase(database: database)
            let seeded = try await seedDeletionFixture(database: database)

            let firstDelete = try await useCase.deleteEntry(entryId: seeded.deletedEntryId)
            let secondDelete = try await useCase.deleteEntry(entryId: seeded.deletedEntryId)
            let missingDelete = try await useCase.deleteEntry(entryId: Int64.max)

            #expect(firstDelete == true)
            #expect(secondDelete == false)
            #expect(missingDelete == false)
        }
    }

    private func seedDeletionFixture(
        database: DatabaseManager,
        activeBatchStatus: TagBatchRunStatus? = nil
    ) async throws -> (
        deletedEntryId: Int64,
        sharedTagId: Int64,
        deletedOnlyTagId: Int64,
        usageEventId: Int64
    ) {
        try await database.write { db in
            let now = Date()

            var feed = Feed(
                id: nil,
                title: "Delete Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: now
            )
            try feed.insert(db)
            let feedId = try #require(feed.id)

            func insertEntry(idSuffix: String, title: String) throws -> Int64 {
                var entry = Entry(
                    id: nil,
                    feedId: feedId,
                    guid: "entry-\(idSuffix)-\(UUID().uuidString)",
                    url: "https://example.com/\(idSuffix)-\(UUID().uuidString)",
                    title: title,
                    author: nil,
                    publishedAt: now,
                    summary: "\(title) summary",
                    isRead: false,
                    isStarred: false,
                    createdAt: now
                )
                try entry.insert(db)
                return try #require(entry.id)
            }

            let deletedEntryId = try insertEntry(idSuffix: "delete", title: "Delete Me")
            let remainingEntryId = try insertEntry(idSuffix: "keep", title: "Keep Me")

            var sharedTag = Tag(
                id: nil,
                name: "Shared",
                normalizedName: "shared",
                isProvisional: false,
                usageCount: 2
            )
            try sharedTag.insert(db)
            let sharedTagId = try #require(sharedTag.id)

            var deletedOnlyTag = Tag(
                id: nil,
                name: "Deleted Only",
                normalizedName: "deleted-only",
                isProvisional: false,
                usageCount: 1
            )
            try deletedOnlyTag.insert(db)
            let deletedOnlyTagId = try #require(deletedOnlyTag.id)

            var deletedSharedTag = EntryTag(
                entryId: deletedEntryId,
                tagId: sharedTagId,
                source: "manual",
                confidence: nil
            )
            try deletedSharedTag.insert(db)

            var remainingSharedTag = EntryTag(
                entryId: remainingEntryId,
                tagId: sharedTagId,
                source: "manual",
                confidence: nil
            )
            try remainingSharedTag.insert(db)

            var deletedOnlyTagAssignment = EntryTag(
                entryId: deletedEntryId,
                tagId: deletedOnlyTagId,
                source: "manual",
                confidence: nil
            )
            try deletedOnlyTagAssignment.insert(db)

            var content = Content(
                id: nil,
                entryId: deletedEntryId,
                html: "<html></html>",
                cleanedHtml: "<article>Body</article>",
                readabilityTitle: "Delete Me",
                readabilityByline: nil,
                readabilityVersion: 1,
                markdown: "Body",
                markdownVersion: 1,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: now,
                documentBaseURL: "https://example.com/delete"
            )
            try content.insert(db)

            var cache = ContentHTMLCache(
                entryId: deletedEntryId,
                themeId: "default",
                html: "<div>Cached</div>",
                readerRenderVersion: 1,
                updatedAt: now
            )
            try cache.insert(db)

            var note = EntryNote(
                entryId: deletedEntryId,
                markdownText: "My note",
                createdAt: now,
                updatedAt: now
            )
            try note.insert(db)

            var summaryRun = AgentTaskRun(
                id: nil,
                entryId: deletedEntryId,
                taskType: .summary,
                status: .succeeded,
                agentProfileId: nil,
                providerProfileId: nil,
                modelProfileId: nil,
                promptVersion: "v1",
                targetLanguage: "en",
                templateId: "summary",
                templateVersion: "v1",
                runtimeParameterSnapshot: nil,
                durationMs: 100,
                createdAt: now,
                updatedAt: now
            )
            try summaryRun.insert(db)
            let summaryRunId = try #require(summaryRun.id)

            var summary = SummaryResult(
                taskRunId: summaryRunId,
                entryId: deletedEntryId,
                targetLanguage: "en",
                detailLevel: .medium,
                outputLanguage: "en",
                text: "Summary",
                createdAt: now,
                updatedAt: now
            )
            try summary.insert(db)

            var translationRun = AgentTaskRun(
                id: nil,
                entryId: deletedEntryId,
                taskType: .translation,
                status: .succeeded,
                agentProfileId: nil,
                providerProfileId: nil,
                modelProfileId: nil,
                promptVersion: "v1",
                targetLanguage: "zh-Hans",
                templateId: "translation",
                templateVersion: "v1",
                runtimeParameterSnapshot: nil,
                durationMs: 120,
                createdAt: now,
                updatedAt: now
            )
            try translationRun.insert(db)
            let translationRunId = try #require(translationRun.id)

            var translation = TranslationResult(
                taskRunId: translationRunId,
                entryId: deletedEntryId,
                targetLanguage: "zh-Hans",
                sourceContentHash: "hash-1",
                segmenterVersion: "seg-1",
                outputLanguage: "zh-Hans",
                runStatus: .succeeded,
                createdAt: now,
                updatedAt: now
            )
            try translation.insert(db)

            var translationSegment = TranslationSegment(
                taskRunId: translationRunId,
                sourceSegmentId: "seg-1",
                orderIndex: 0,
                sourceTextSnapshot: "Body",
                translatedText: "正文",
                createdAt: now,
                updatedAt: now
            )
            try translationSegment.insert(db)

            var taggingRun = AgentTaskRun(
                id: nil,
                entryId: deletedEntryId,
                taskType: .tagging,
                status: .cancelled,
                agentProfileId: nil,
                providerProfileId: nil,
                modelProfileId: nil,
                promptVersion: "v1",
                targetLanguage: nil,
                templateId: "tagging",
                templateVersion: "v1",
                runtimeParameterSnapshot: nil,
                durationMs: 80,
                createdAt: now,
                updatedAt: now
            )
            try taggingRun.insert(db)
            let taggingRunId = try #require(taggingRun.id)

            var usageEvent = LLMUsageEvent(
                id: nil,
                taskRunId: taggingRunId,
                entryId: deletedEntryId,
                taskType: .tagging,
                providerProfileId: nil,
                modelProfileId: nil,
                providerBaseURLSnapshot: "http://localhost:5810/v1",
                providerResolvedURLSnapshot: "http://localhost:5810/v1/chat/completions",
                providerResolvedHostSnapshot: "localhost",
                providerResolvedPathSnapshot: "/v1/chat/completions",
                providerNameSnapshot: "local",
                modelNameSnapshot: "qwen3",
                requestPhase: .normal,
                requestStatus: .cancelled,
                promptTokens: 10,
                completionTokens: 0,
                totalTokens: 10,
                usageAvailability: .actual,
                startedAt: now,
                finishedAt: now,
                createdAt: now
            )
            try usageEvent.insert(db)
            let usageEventId = try #require(usageEvent.id)

            var doneRun = TagBatchRun(
                id: nil,
                status: activeBatchStatus ?? .done,
                scopeLabel: "all_entries",
                skipAlreadyApplied: true,
                skipAlreadyTagged: true,
                concurrency: 3,
                totalSelectedEntries: 1,
                totalPlannedEntries: 1,
                processedEntries: 1,
                succeededEntries: 1,
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
            try doneRun.insert(db)
            let runId = try #require(doneRun.id)

            var batchEntry = TagBatchEntry(
                id: nil,
                runId: runId,
                entryId: deletedEntryId,
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

            var batchAssignment = TagBatchAssignmentStaging(
                id: nil,
                runId: runId,
                entryId: deletedEntryId,
                normalizedName: "swift",
                displayName: "Swift",
                resolvedTagId: sharedTagId,
                assignmentKind: .matched,
                createdAt: now,
                updatedAt: now
            )
            try batchAssignment.insert(db)

            return (
                deletedEntryId: deletedEntryId,
                sharedTagId: sharedTagId,
                deletedOnlyTagId: deletedOnlyTagId,
                usageEventId: usageEventId
            )
        }
    }
}
