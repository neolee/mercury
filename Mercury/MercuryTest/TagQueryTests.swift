import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tag Query")
@MainActor
struct TagQueryTests {
    @Test("EntryListQuery tagMatchMode any/all filters correctly")
    @MainActor
    func tagAnyAllFilteringWorks() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let store = EntryStore(db: manager)
            let feedId = try await insertFeed(database: manager)

            let entryA = try await insertEntry(database: manager, feedId: feedId, title: "Only Swift", isRead: false, sortOffset: 3)
            let entryB = try await insertEntry(database: manager, feedId: feedId, title: "Only AI", isRead: true, sortOffset: 2)
            let entryC = try await insertEntry(database: manager, feedId: feedId, title: "Swift and AI", isRead: false, sortOffset: 1)

            try await store.assignTags(to: entryA, names: ["swift"], source: "manual")
            try await store.assignTags(to: entryB, names: ["ai"], source: "manual")
            try await store.assignTags(to: entryC, names: ["swift", "ai"], source: "manual")

            let tagIdsByName = try await manager.read { db in
                let tags = try Tag.fetchAll(db)
                return Dictionary(uniqueKeysWithValues: tags.map { ($0.normalizedName, $0.id ?? 0) })
            }

            guard let swiftTagId = tagIdsByName["swift"], let aiTagId = tagIdsByName["ai"] else {
                throw TestError.missingTagIDs
            }

            _ = await store.loadFirstPage(
                query: EntryStore.EntryListQuery(
                    feedId: feedId,
                    unreadOnly: false,
                    starredOnly: false,
                    keepEntryId: nil,
                    searchText: nil,
                    tagIds: [swiftTagId, aiTagId],
                    tagMatchMode: .any
                )
            )

            #expect(Set(store.entries.map(\.id)) == Set([entryA, entryB, entryC]))

            _ = await store.loadFirstPage(
                query: EntryStore.EntryListQuery(
                    feedId: feedId,
                    unreadOnly: false,
                    starredOnly: false,
                    keepEntryId: nil,
                    searchText: nil,
                    tagIds: [swiftTagId, aiTagId],
                    tagMatchMode: .all
                )
            )

            #expect(store.entries.count == 1)
            #expect(store.entries.first?.id == entryC)

            _ = await store.loadFirstPage(
                query: EntryStore.EntryListQuery(
                    feedId: feedId,
                    unreadOnly: true,
                    starredOnly: false,
                    keepEntryId: nil,
                    searchText: nil,
                    tagIds: [swiftTagId, aiTagId],
                    tagMatchMode: .any
                )
            )

            #expect(Set(store.entries.map(\.id)) == Set([entryA, entryC]))
        }
    }

    private func insertFeed(database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "Tag Query Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw TestError.missingFeed
            }
            return feedId
        }
    }

    private func insertEntry(
        database: DatabaseManager,
        feedId: Int64,
        title: String,
        isRead: Bool,
        sortOffset: TimeInterval
    ) async throws -> Int64 {
        try await database.write { db in
            let timestamp = Date().addingTimeInterval(sortOffset)
            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "entry-\(UUID().uuidString)",
                url: "https://example.com/entry-\(UUID().uuidString)",
                title: title,
                author: nil,
                publishedAt: timestamp,
                summary: title,
                isRead: isRead,
                isStarred: false,
                createdAt: timestamp
            )
            try entry.insert(db)
            guard let entryId = entry.id else {
                throw TestError.missingEntry
            }
            return entryId
        }
    }
    private enum TestError: Error {
        case missingFeed
        case missingEntry
        case missingTagIDs
    }
}
