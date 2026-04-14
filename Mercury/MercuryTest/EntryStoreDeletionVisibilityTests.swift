import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("EntryStore Deletion Visibility")
@MainActor
struct EntryStoreDeletionVisibilityTests {
    @Test("Deleted entries are hidden from list detail and related-entry reads")
    @MainActor
    func deletedEntriesAreHiddenFromListDetailAndRelatedReads() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = EntryStore(db: database)
            let feedId = try await insertFeed(database: database)

            let anchorEntryId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Anchor",
                publishedAt: Date().addingTimeInterval(30)
            )
            let visibleRelatedEntryId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Visible Related",
                publishedAt: Date().addingTimeInterval(20)
            )
            let deletedRelatedEntryId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Deleted Related",
                publishedAt: Date().addingTimeInterval(10)
            )

            let sharedTagId = try await insertTag(database: database, name: "Swift")
            try await attachTag(database: database, entryId: anchorEntryId, tagId: sharedTagId)
            try await attachTag(database: database, entryId: visibleRelatedEntryId, tagId: sharedTagId)
            try await attachTag(database: database, entryId: deletedRelatedEntryId, tagId: sharedTagId)

            try await database.write { db in
                _ = try Entry
                    .filter(Column("id") == deletedRelatedEntryId)
                    .updateAll(db, Column("isDeleted").set(to: true))
            }

            _ = await store.loadFirstPage(
                query: EntryStore.EntryListQuery(
                    feedId: feedId,
                    unreadOnly: false,
                    starredOnly: false,
                    keepEntryId: nil,
                    searchText: nil
                )
            )

            #expect(store.entries.map(\.id) == [anchorEntryId, visibleRelatedEntryId])
            #expect(await store.loadEntry(id: visibleRelatedEntryId)?.id == visibleRelatedEntryId)
            #expect(await store.loadEntry(id: deletedRelatedEntryId) == nil)

            let relatedEntries = await store.fetchRelatedEntries(for: anchorEntryId, limit: 5)
            #expect(relatedEntries.map(\.id) == [visibleRelatedEntryId])
        }
    }

    @Test("Targeted entry writes are no-ops for deleted rows")
    @MainActor
    func targetedEntryWritesAreNoOpsForDeletedRows() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = EntryStore(db: database)
            let feedId = try await insertFeed(database: database)
            let deletedEntryId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Deleted Entry",
                publishedAt: Date(),
                isRead: false,
                isStarred: false,
                url: "https://example.com/original"
            )

            try await database.write { db in
                _ = try Entry
                    .filter(Column("id") == deletedEntryId)
                    .updateAll(db, Column("isDeleted").set(to: true))
            }

            try await store.markRead(entryId: deletedEntryId, isRead: true)
            try await store.markRead(entryIds: [deletedEntryId], isRead: true)
            try await store.markStarred(entryId: deletedEntryId, isStarred: true)
            try await store.updateURL(entryId: deletedEntryId, url: "https://example.com/updated")

            let persistedEntry = try await database.read { db in
                try Entry
                    .filter(Column("id") == deletedEntryId)
                    .fetchOne(db)
            }

            let entry = try #require(persistedEntry)
            #expect(entry.isDeleted == true)
            #expect(entry.isRead == false)
            #expect(entry.isStarred == false)
            #expect(entry.url == "https://example.com/original")
        }
    }

    private func insertFeed(database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "EntryStore Deletion Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            return try #require(feed.id)
        }
    }

    private func insertEntry(
        database: DatabaseManager,
        feedId: Int64,
        title: String,
        publishedAt: Date,
        isRead: Bool = false,
        isStarred: Bool = false,
        url: String? = nil
    ) async throws -> Int64 {
        try await database.write { db in
            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "entry-\(UUID().uuidString)",
                url: url ?? "https://example.com/\(UUID().uuidString)",
                title: title,
                author: nil,
                publishedAt: publishedAt,
                summary: "\(title) summary",
                isRead: isRead,
                isStarred: isStarred,
                createdAt: publishedAt
            )
            try entry.insert(db)
            return try #require(entry.id)
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
            return try #require(tag.id)
        }
    }

    private func attachTag(database: DatabaseManager, entryId: Int64, tagId: Int64) async throws {
        try await database.write { db in
            var entryTag = EntryTag(entryId: entryId, tagId: tagId, source: "manual", confidence: nil)
            try entryTag.insert(db)
        }
    }
}
