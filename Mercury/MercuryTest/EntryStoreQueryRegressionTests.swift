import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("EntryStore Query Regression")
struct EntryStoreQueryRegressionTests {
    @Test("Search matches title and summary only")
    @MainActor
    func searchMatchesTitleAndSummaryOnly() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let feedId = try await insertFeed(database: database)
            let store = EntryStore(db: database)

            let titleMatchId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Swift title match",
                author: "Author",
                url: "https://example.com/title",
                summary: "No summary hit",
                publishedAt: Date().addingTimeInterval(30)
            )
            let summaryMatchId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "No title hit",
                author: "Author",
                url: "https://example.com/summary",
                summary: "Swift summary match",
                publishedAt: Date().addingTimeInterval(20)
            )
            _ = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "No search hit",
                author: "Swift author only",
                url: "https://example.com/author",
                summary: "No match",
                publishedAt: Date().addingTimeInterval(10)
            )
            _ = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Still no hit",
                author: "Author",
                url: "https://swift.example.com/url-only",
                summary: "No match",
                publishedAt: Date()
            )

            _ = await store.loadFirstPage(
                query: EntryStore.EntryListQuery(
                    feedId: feedId,
                    unreadOnly: false,
                    starredOnly: false,
                    keepEntryId: nil,
                    searchText: "swift"
                )
            )

            #expect(Set(store.entries.map(\.id)) == Set([titleMatchId, summaryMatchId]))
        }
    }

    @Test("Unread keepEntryId injects pinned row on first page")
    @MainActor
    func unreadKeepEntryInjectionIncludesPinnedRowOnFirstPage() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let feedId = try await insertFeed(database: database)
            let store = EntryStore(db: database)

            let pinnedReadEntryId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Pinned read entry",
                author: nil,
                url: "https://example.com/pinned",
                summary: "Pinned",
                isRead: true,
                publishedAt: Date().addingTimeInterval(30)
            )
            let unreadEntryId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Unread entry",
                author: nil,
                url: "https://example.com/unread",
                summary: "Unread",
                isRead: false,
                publishedAt: Date().addingTimeInterval(20)
            )

            _ = await store.loadFirstPage(
                query: EntryStore.EntryListQuery(
                    feedId: feedId,
                    unreadOnly: true,
                    starredOnly: false,
                    keepEntryId: pinnedReadEntryId,
                    searchText: nil
                )
            )

            #expect(store.entries.map(\.id) == [pinnedReadEntryId, unreadEntryId])
        }
    }

    @Test("Search disables keepEntryId injection")
    @MainActor
    func searchDisablesKeepEntryInjection() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let feedId = try await insertFeed(database: database)
            let store = EntryStore(db: database)

            let pinnedReadEntryId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Pinned read entry",
                author: nil,
                url: "https://example.com/pinned",
                summary: "Pinned",
                isRead: true,
                publishedAt: Date().addingTimeInterval(20)
            )
            let matchingUnreadEntryId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Swift unread entry",
                author: nil,
                url: "https://example.com/unread",
                summary: "Unread",
                isRead: false,
                publishedAt: Date().addingTimeInterval(10)
            )

            _ = await store.loadFirstPage(
                query: EntryStore.EntryListQuery(
                    feedId: feedId,
                    unreadOnly: true,
                    starredOnly: false,
                    keepEntryId: pinnedReadEntryId,
                    searchText: "swift"
                )
            )

            #expect(store.entries.map(\.id) == [matchingUnreadEntryId])
        }
    }

    @Test("Pagination preserves descending publishedAt createdAt id order")
    @MainActor
    func paginationPreservesCursorOrdering() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let feedId = try await insertFeed(database: database)
            let store = EntryStore(db: database)
            let baseDate = Date()

            let newestId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Newest",
                author: nil,
                url: "https://example.com/newest",
                summary: "Newest",
                publishedAt: baseDate.addingTimeInterval(30),
                createdAt: baseDate.addingTimeInterval(30)
            )
            let middleId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Middle",
                author: nil,
                url: "https://example.com/middle",
                summary: "Middle",
                publishedAt: baseDate.addingTimeInterval(20),
                createdAt: baseDate.addingTimeInterval(20)
            )
            let oldestId = try await insertEntry(
                database: database,
                feedId: feedId,
                title: "Oldest",
                author: nil,
                url: "https://example.com/oldest",
                summary: "Oldest",
                publishedAt: baseDate.addingTimeInterval(10),
                createdAt: baseDate.addingTimeInterval(10)
            )

            let query = EntryStore.EntryListQuery(
                feedId: feedId,
                unreadOnly: false,
                starredOnly: false,
                keepEntryId: nil,
                searchText: nil
            )
            let orderedIDs = try await database.read { db in
                try Int64.fetchAll(
                    db,
                    sql: """
                    SELECT id
                    FROM entry
                    WHERE feedId = ?
                    ORDER BY publishedAt DESC, createdAt DESC, id DESC
                    """,
                    arguments: [feedId]
                )
            }
            let firstPage = await store.loadFirstPage(query: query, batchSize: 2)

            #expect(orderedIDs == [newestId, middleId, oldestId])
            #expect(store.entries.map(\.id) == Array(orderedIDs.prefix(2)))
            #expect(firstPage.hasMore == true)

            let cursor = try #require(firstPage.nextCursor)
            let secondPage = await store.loadNextPage(query: query, after: cursor, batchSize: 2)

            #expect(store.entries.map(\.id) == orderedIDs)
            #expect(secondPage.hasMore == false)
            #expect(secondPage.nextCursor?.id == orderedIDs.last)
        }
    }

    private func insertFeed(database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "EntryStore Query Feed",
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
        author: String?,
        url: String?,
        summary: String?,
        isRead: Bool = false,
        publishedAt: Date,
        createdAt: Date? = nil
    ) async throws -> Int64 {
        try await database.write { db in
            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "entry-\(UUID().uuidString)",
                url: url,
                title: title,
                author: author,
                publishedAt: publishedAt,
                summary: summary,
                isRead: isRead,
                isStarred: false,
                createdAt: createdAt ?? publishedAt
            )
            try entry.insert(db)
            return try #require(entry.id)
        }
    }
}
