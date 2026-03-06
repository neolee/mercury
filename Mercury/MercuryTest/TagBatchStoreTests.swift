import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tag Batch Store")
struct TagBatchStoreTests {
    @Test("Can create run and move through running to review")
    @MainActor
    func createAndTransitionRun() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let store = TagBatchStore(db: fixture.database)

            let runId = try await store.createRun(
                scopeLabel: "past_week",
                skipAlreadyApplied: true,
                skipAlreadyTagged: true,
                concurrency: 3,
                totalSelectedEntries: 10,
                totalPlannedEntries: 10
            )
            #expect(runId > 0)

            try await store.updateRunStatus(runId: runId, status: .running, startedAt: Date())
            try await store.updateRunCounters(runId: runId, processedEntries: 4, succeededEntries: 3, failedEntries: 1)
            try await store.updateRunPlannedCount(runId: runId, totalPlannedEntries: 8)

            let active = try await store.loadActiveRun()
            #expect(active?.id == runId)
            #expect(active?.status == .running)
            #expect(active?.skipAlreadyApplied == true)
            #expect(active?.skipAlreadyTagged == true)
            #expect(active?.processedEntries == 4)
            #expect(active?.succeededEntries == 3)
            #expect(active?.failedEntries == 1)
            #expect(active?.totalPlannedEntries == 8)

            try await store.updateRunStatus(runId: runId, status: .review)
            let reviewRun = try await store.loadRun(id: runId)
            #expect(reviewRun?.status == .review)
        }
    }

    @Test("Rebuild review rows aggregates staged new proposals")
    @MainActor
    func rebuildReviewRows() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database
            let store = TagBatchStore(db: db)

            let runId = try await store.createRun(
                scopeLabel: "all_entries",
                skipAlreadyApplied: false,
                skipAlreadyTagged: false,
                concurrency: 2,
                totalSelectedEntries: 2,
                totalPlannedEntries: 2
            )

            try await db.write { db in
                var feed = Feed(
                    id: nil,
                    title: "Feed",
                    feedURL: "https://example.com/rss",
                    siteURL: "https://example.com",
                    lastFetchedAt: nil,
                    createdAt: Date()
                )
                try feed.insert(db)
                let feedId = try #require(feed.id)

                var entry1 = Entry(
                    id: nil,
                    feedId: feedId,
                    guid: "1",
                    url: "https://example.com/1",
                    title: "One",
                    author: nil,
                    publishedAt: Date(),
                    summary: "S1",
                    isRead: false,
                    isStarred: false,
                    createdAt: Date()
                )
                try entry1.insert(db)

                var entry2 = Entry(
                    id: nil,
                    feedId: feedId,
                    guid: "2",
                    url: "https://example.com/2",
                    title: "Two",
                    author: nil,
                    publishedAt: Date(),
                    summary: "S2",
                    isRead: false,
                    isStarred: false,
                    createdAt: Date()
                )
                try entry2.insert(db)

                let e1 = try #require(entry1.id)
                let e2 = try #require(entry2.id)

                var existingTag = Tag(
                    id: nil,
                    name: "AI",
                    normalizedName: "ai",
                    isProvisional: false,
                    usageCount: 1
                )
                try existingTag.insert(db)
                let aiTagId = try #require(existingTag.id)

                var a1 = TagBatchAssignmentStaging(
                    id: nil,
                    runId: runId,
                    entryId: e1,
                    normalizedName: "swift",
                    displayName: "Swift",
                    resolvedTagId: nil,
                    assignmentKind: .newProposal,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                try a1.insert(db)

                var a2 = TagBatchAssignmentStaging(
                    id: nil,
                    runId: runId,
                    entryId: e2,
                    normalizedName: "swift",
                    displayName: "Swift",
                    resolvedTagId: nil,
                    assignmentKind: .newProposal,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                try a2.insert(db)

                var matched = TagBatchAssignmentStaging(
                    id: nil,
                    runId: runId,
                    entryId: e2,
                    normalizedName: "ai",
                    displayName: "AI",
                    resolvedTagId: aiTagId,
                    assignmentKind: .matched,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                try matched.insert(db)
            }

            try await store.rebuildReviewRowsFromAssignments(runId: runId)
            let rows = try await store.loadReviewRows(runId: runId)
            #expect(rows.count == 1)
            #expect(rows.first?.normalizedName == "swift")
            #expect(rows.first?.hitCount == 2)
            #expect(rows.first?.sampleEntryCount == 2)
            #expect(rows.first?.decision == .pending)
        }
    }
}
