import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("SidebarCountStore")
struct SidebarCountStoreTests {

    // MARK: - Read state propagation

    @Test("Read toggle updates totalUnread, per-feed badge, and tag unreadCount")
    @MainActor
    func readToggleUpdatesAllRelevantCounters() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let feedId = try await insertFeed(database: manager)
            let entryId = try await insertEntry(database: manager, feedId: feedId, isRead: false, isStarred: false)

            try await manager.write { db in
                var tag = Tag(id: nil, name: "Swift", normalizedName: "swift", isProvisional: false, usageCount: 1)
                try tag.insert(db)
                guard let tagId = tag.id else { throw TestError.missingTagID }
                var entryTag = EntryTag(entryId: entryId, tagId: tagId, source: "manual", confidence: nil)
                try entryTag.insert(db)
            }

            let store = SidebarCountStore(database: manager)
            defer { store.stopObservation() }

            try await waitUntil {
                store.projection.totalUnread == 1
                    && store.projection.feedUnreadCounts[feedId] == 1
                    && store.projection.tags.first?.unreadCount == 1
            }

            try await manager.write { db in
                _ = try Entry.filter(Column("id") == entryId).updateAll(db, Column("isRead").set(to: true))
            }

            try await waitUntil {
                store.projection.totalUnread == 0
                    && store.projection.feedUnreadCounts[feedId] == nil
                    && store.projection.tags.first?.unreadCount == 0
            }
        }
    }

    @Test("Batch read update propagates totalUnread and per-feed badges correctly")
    @MainActor
    func batchReadUpdatePropagatesCounters() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let feedA = try await insertFeed(database: manager)
            let feedB = try await insertFeed(database: manager)

            let entryA1 = try await insertEntry(database: manager, feedId: feedA, isRead: false, isStarred: false)
            let entryA2 = try await insertEntry(database: manager, feedId: feedA, isRead: false, isStarred: false)
            let entryB1 = try await insertEntry(database: manager, feedId: feedB, isRead: false, isStarred: false)

            let store = SidebarCountStore(database: manager)
            defer { store.stopObservation() }

            try await waitUntil {
                store.projection.totalUnread == 3
                    && store.projection.feedUnreadCounts[feedA] == 2
                    && store.projection.feedUnreadCounts[feedB] == 1
            }

            try await manager.write { db in
                _ = try Entry
                    .filter(Column("id") == entryA1 || Column("id") == entryA2)
                    .updateAll(db, Column("isRead").set(to: true))
            }

            try await waitUntil {
                store.projection.totalUnread == 1
                    && store.projection.feedUnreadCounts[feedA] == nil
                    && store.projection.feedUnreadCounts[feedB] == 1
            }

            _ = entryB1
        }
    }

    // MARK: - Starred state propagation

    @Test("Starring and reading an entry updates starred counters")
    @MainActor
    func starringEntryUpdatesStarredCounters() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let feedId = try await insertFeed(database: manager)
            let entryId = try await insertEntry(database: manager, feedId: feedId, isRead: false, isStarred: false)

            let store = SidebarCountStore(database: manager)
            defer { store.stopObservation() }

            try await waitUntil {
                store.projection.totalStarred == 0 && store.projection.starredUnread == 0
            }

            try await manager.write { db in
                _ = try Entry.filter(Column("id") == entryId).updateAll(db, Column("isStarred").set(to: true))
            }

            try await waitUntil {
                store.projection.totalStarred == 1 && store.projection.starredUnread == 1
            }

            try await manager.write { db in
                _ = try Entry.filter(Column("id") == entryId).updateAll(db, Column("isRead").set(to: true))
            }

            try await waitUntil {
                store.projection.totalStarred == 1 && store.projection.starredUnread == 0
            }

            try await manager.write { db in
                _ = try Entry.filter(Column("id") == entryId).updateAll(db, Column("isStarred").set(to: false))
            }

            try await waitUntil { store.projection.totalStarred == 0 }
        }
    }

    // MARK: - Tag state propagation

    @Test("Tag insertion and entry-tag association updates projection tag list and counts")
    @MainActor
    func tagInsertionAndAssociationUpdatesProjection() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let feedId = try await insertFeed(database: manager)
            let entryId = try await insertEntry(database: manager, feedId: feedId, isRead: false, isStarred: false)

            let store = SidebarCountStore(database: manager)
            defer { store.stopObservation() }

            try await waitUntil { store.projection.tags.isEmpty }

            let tagId: Int64 = try await manager.write { db in
                var tag = Tag(id: nil, name: "AI", normalizedName: "ai", isProvisional: false, usageCount: 1)
                try tag.insert(db)
                guard let id = tag.id else { throw TestError.missingTagID }
                var entryTag = EntryTag(entryId: entryId, tagId: id, source: "manual", confidence: nil)
                try entryTag.insert(db)
                return id
            }

            try await waitUntil {
                store.projection.tags.count == 1
                    && store.projection.tags.first?.tagId == tagId
                    && store.projection.tags.first?.usageCount == 1
                    && store.projection.tags.first?.unreadCount == 1
            }

            try await manager.write { db in
                _ = try Entry.filter(Column("id") == entryId).updateAll(db, Column("isRead").set(to: true))
            }

            try await waitUntil {
                store.projection.tags.first?.unreadCount == 0
                    && store.projection.tags.first?.usageCount == 1
            }
        }
    }

    // MARK: - Visibility policy

    @Test("Visibility policy hides provisional tags when total exceeds threshold")
    @MainActor
    func visibilityPolicyHidesProvisionalTagsAboveThreshold() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database

            let tagCount = SidebarTagVisibilityPolicy.provisionalHiddenThreshold + 1
            for i in 0..<tagCount {
                try await manager.write { db in
                    var tag = Tag(
                        id: nil,
                        name: "ProvisionalTag\(i)",
                        normalizedName: "provisionaltag\(i)",
                        isProvisional: true,
                        usageCount: 0
                    )
                    try tag.insert(db)
                }
            }

            let store = SidebarCountStore(database: manager)
            defer { store.stopObservation() }

            try await waitUntil { store.projection.tags.isEmpty }

            try await manager.write { db in
                _ = try Tag
                    .filter(Column("normalizedName") == "provisionaltag0")
                    .updateAll(db, Column("isProvisional").set(to: false))
            }

            try await waitUntil {
                store.projection.tags.count == 1
                    && store.projection.tags.first?.normalizedName == "provisionaltag0"
            }
        }
    }

    @Test("Visibility policy shows all tags when total is at or below threshold")
    @MainActor
    func visibilityPolicyShowsAllTagsAtOrBelowThreshold() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database

            let tagCount = SidebarTagVisibilityPolicy.provisionalHiddenThreshold
            for i in 0..<tagCount {
                try await manager.write { db in
                    var tag = Tag(
                        id: nil,
                        name: "Tag\(i)",
                        normalizedName: "tag\(i)",
                        isProvisional: true,
                        usageCount: 0
                    )
                    try tag.insert(db)
                }
            }

            let store = SidebarCountStore(database: manager)
            defer { store.stopObservation() }

            try await waitUntil { store.projection.tags.count == tagCount }
            #expect(store.projection.tags.allSatisfy { $0.isProvisional == true })
        }
    }

    // MARK: - Equivalence baseline

    @Test("Projection values match direct SQL queries on the same database snapshot")
    @MainActor
    func equivalenceBaselineMatchesManualQueries() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let feedId = try await insertFeed(database: manager)

            let entryA = try await insertEntry(database: manager, feedId: feedId, isRead: false, isStarred: true)
            let entryB = try await insertEntry(database: manager, feedId: feedId, isRead: true, isStarred: true)
            let entryC = try await insertEntry(database: manager, feedId: feedId, isRead: false, isStarred: false)

            try await manager.write { db in
                var tag = Tag(id: nil, name: "Test", normalizedName: "test", isProvisional: false, usageCount: 2)
                try tag.insert(db)
                guard let tagId = tag.id else { throw TestError.missingTagID }
                var et1 = EntryTag(entryId: entryA, tagId: tagId, source: "manual", confidence: nil)
                try et1.insert(db)
                var et2 = EntryTag(entryId: entryB, tagId: tagId, source: "manual", confidence: nil)
                try et2.insert(db)
            }

            let expected = try await manager.read { db -> (Int, Int, Int, Int, Int) in
                let totalUnread = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE isRead = 0") ?? 0
                let totalStarred = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE isStarred = 1") ?? 0
                let starredUnread = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM entry WHERE isStarred = 1 AND isRead = 0"
                ) ?? 0
                let feedUnread = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM entry WHERE isRead = 0 AND feedId = ?",
                    arguments: [feedId]
                ) ?? 0
                let tagUnread = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(e.id)
                    FROM entry_tag et
                    JOIN entry e ON e.id = et.entryId
                    JOIN tag t ON t.id = et.tagId
                    WHERE e.isRead = 0 AND t.normalizedName = 'test'
                    """
                ) ?? 0
                return (totalUnread, totalStarred, starredUnread, feedUnread, tagUnread)
            }

            let store = SidebarCountStore(database: manager)
            defer { store.stopObservation() }

            try await waitUntil {
                store.projection.totalUnread == expected.0
                    && store.projection.totalStarred == expected.1
                    && store.projection.starredUnread == expected.2
            }

            let projection = store.projection
            #expect(projection.totalUnread == expected.0)
            #expect(projection.totalStarred == expected.1)
            #expect(projection.starredUnread == expected.2)
            #expect((projection.feedUnreadCounts[feedId] ?? 0) == expected.3)
            #expect(projection.tags.first(where: { $0.normalizedName == "test" })?.unreadCount == expected.4)

            _ = (entryB, entryC)
        }
    }

    // MARK: - Helpers

    private func insertFeed(database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "SidebarCountStore Test Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else { throw TestError.missingFeedID }
            return feedId
        }
    }

    private func insertEntry(
        database: DatabaseManager,
        feedId: Int64,
        isRead: Bool,
        isStarred: Bool
    ) async throws -> Int64 {
        try await database.write { db in
            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "entry-\(UUID().uuidString)",
                url: "https://example.com/entry-\(UUID().uuidString)",
                title: "Test Entry",
                author: nil,
                publishedAt: Date(),
                summary: "summary",
                isRead: isRead,
                isStarred: isStarred,
                createdAt: Date()
            )
            try entry.insert(db)
            guard let entryId = entry.id else { throw TestError.missingEntryID }
            return entryId
        }
    }
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        predicate: @escaping () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while predicate() == false {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - start > timeoutNanoseconds {
                throw TestError.timeout
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private enum TestError: Error {
        case missingFeedID
        case missingEntryID
        case missingTagID
        case timeout
    }
}
