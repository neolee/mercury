import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tags Database")
struct TagsDatabaseTests {
    @Test("Migration creates tag tables and indexes")
    @MainActor
    func migrationCreatesTagTablesAndIndexes() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database

            try manager.dbQueue.read { db in
                #expect(try db.tableExists("tag"))
                #expect(try db.tableExists("tag_alias"))
                #expect(try db.tableExists("entry_tag"))

                let tagColumns = try Set(db.columns(in: "tag").map(\.name))
                #expect(tagColumns.contains("name"))
                #expect(tagColumns.contains("normalizedName"))
                #expect(tagColumns.contains("isProvisional"))
                #expect(tagColumns.contains("usageCount"))

                let aliasColumns = try Set(db.columns(in: "tag_alias").map(\.name))
                #expect(aliasColumns.contains("tagId"))
                #expect(aliasColumns.contains("alias"))
                #expect(aliasColumns.contains("normalizedAlias"))

                let entryTagColumns = try Set(db.columns(in: "entry_tag").map(\.name))
                #expect(entryTagColumns.contains("entryId"))
                #expect(entryTagColumns.contains("tagId"))
                #expect(entryTagColumns.contains("source"))
                #expect(entryTagColumns.contains("confidence"))

                let tagIndexNames = try Set(db.indexes(on: "tag").map(\.name))
                #expect(tagIndexNames.contains("idx_tag_normalized_name"))

                let aliasIndexNames = try Set(db.indexes(on: "tag_alias").map(\.name))
                #expect(aliasIndexNames.contains("idx_tag_alias_normalized_alias"))

                let entryTagIndexNames = try Set(db.indexes(on: "entry_tag").map(\.name))
                #expect(entryTagIndexNames.contains("idx_entry_tag_tag_entry"))
            }
        }
    }

    @Test("Entry tags association fetches assigned tags")
    @MainActor
    func entryTagsAssociationFetchesAssignedTags() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let feedId = try await insertFeed(database: manager)
            let entryId = try await insertEntry(database: manager, feedId: feedId, title: "Tagged Entry")

            try await manager.write { db in
                var tag = Tag(
                    id: nil,
                    name: "Swift",
                    normalizedName: "swift",
                    isProvisional: false,
                    usageCount: 1
                )
                try tag.insert(db)
                guard let tagId = tag.id else {
                    throw TestError.missingTagID
                }

                var entryTag = EntryTag(entryId: entryId, tagId: tagId, source: "manual", confidence: nil)
                try entryTag.insert(db)
            }

            try await manager.read { db in
                guard let entry = try Entry.fetchOne(db, key: entryId) else {
                    throw TestError.missingEntryID
                }

                let tags = try entry.request(for: Entry.tags).fetchAll(db)
                #expect(tags.count == 1)
                #expect(tags.first?.normalizedName == "swift")
            }
        }
    }

    @Test("Rename and delete tag are blocked for every active batch lifecycle state")
    @MainActor
    func destructiveTagMutationsBlockedDuringActiveBatchLifecycle() async throws {
        for status in TagBatchRunStatus.activeLifecycleStatuses {
            try await InMemoryDatabaseFixture.withFixture { fixture in
                let manager = fixture.database
                let feedId = try await insertFeed(database: manager)
                _ = try await insertEntry(database: manager, feedId: feedId, title: "Tagged Entry")
                let store = EntryStore(db: manager)

                let renameTagId = try await insertTag(database: manager, name: "Swift")
                let deleteTagId = try await insertTag(database: manager, name: "AI")
                try await insertBatchRun(database: manager, status: status)

                do {
                    try await store.renameTag(id: renameTagId, newName: "SwiftUI")
                    Issue.record("Expected renameTag to be blocked for active batch status \(status.rawValue).")
                } catch let error as TagMutationError {
                    #expect(error == .batchRunActive)
                }

                do {
                    try await store.deleteTag(id: deleteTagId)
                    Issue.record("Expected deleteTag to be blocked for active batch status \(status.rawValue).")
                } catch let error as TagMutationError {
                    #expect(error == .batchRunActive)
                }
            }
        }
    }

    private func insertFeed(database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "Tag Test Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw TestError.missingFeedID
            }
            return feedId
        }
    }

    private func insertEntry(database: DatabaseManager, feedId: Int64, title: String) async throws -> Int64 {
        try await database.write { db in
            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "entry-\(UUID().uuidString)",
                url: "https://example.com/entry-\(UUID().uuidString)",
                title: title,
                author: nil,
                publishedAt: Date(),
                summary: title,
                isRead: false,
                isStarred: false,
                createdAt: Date()
            )
            try entry.insert(db)
            guard let entryId = entry.id else {
                throw TestError.missingEntryID
            }
            return entryId
        }
    }

    private func insertTag(database: DatabaseManager, name: String) async throws -> Int64 {
        try await database.write { db in
            var tag = Tag(
                id: nil,
                name: name,
                normalizedName: TagNormalization.normalize(name),
                isProvisional: false,
                usageCount: 0
            )
            try tag.insert(db)
            guard let tagId = tag.id else {
                throw TestError.missingTagID
            }
            return tagId
        }
    }

    private func insertBatchRun(database: DatabaseManager, status: TagBatchRunStatus) async throws {
        try await database.write { db in
            var run = TagBatchRun(
                id: nil,
                status: status,
                scopeLabel: "all_entries",
                skipAlreadyApplied: true,
                skipAlreadyTagged: true,
                concurrency: 3,
                totalSelectedEntries: 1,
                totalPlannedEntries: 1,
                processedEntries: 0,
                succeededEntries: 0,
                failedEntries: 0,
                keptProposalCount: 0,
                discardedProposalCount: 0,
                insertedEntryTagCount: 0,
                createdTagCount: 0,
                startedAt: nil,
                completedAt: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
            try run.insert(db)
        }
    }

    private enum TestError: Error {
        case missingFeedID
        case missingEntryID
        case missingTagID
    }
}
