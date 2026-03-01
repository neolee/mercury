import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("EntryStore Starred")
struct EntryStoreStarredTests {
    @Test("Migration adds isStarred with default false")
    @MainActor
    func migrationAddsIsStarredDefaultFalse() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let manager = try DatabaseManager(path: dbPath)
        let feedId = try await insertFeed(database: manager)
        let entryId = try await manager.write { db in
            try db.execute(sql: "INSERT INTO entry (feedId, title) VALUES (?, ?)", arguments: [feedId, "Default Star"])
            return db.lastInsertedRowID
        }

        let isStarred = try await manager.read { db in
            try Bool.fetchOne(db, sql: "SELECT isStarred FROM entry WHERE id = ?", arguments: [entryId])
        }
        #expect(isStarred == false)
    }

    @Test("starredOnly query returns starred rows only")
    @MainActor
    func starredOnlyQueryFiltersEntries() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let manager = try DatabaseManager(path: dbPath)
        let (feedId, starredEntryId, _) = try await seedTwoEntries(database: manager)
        let store = EntryStore(db: manager)

        _ = await store.loadFirstPage(
            query: EntryStore.EntryListQuery(
                feedId: feedId,
                unreadOnly: false,
                starredOnly: true,
                keepEntryId: nil,
                searchText: nil
            )
        )

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.id == starredEntryId)
        #expect(store.entries.first?.isStarred == true)
    }

    @Test("markStarred updates in-memory row and database")
    @MainActor
    func markStarredUpdatesInMemoryAndDatabase() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let manager = try DatabaseManager(path: dbPath)
        let (feedId, _, unstarredEntryId) = try await seedTwoEntries(database: manager)
        let store = EntryStore(db: manager)

        _ = await store.loadFirstPage(
            query: EntryStore.EntryListQuery(
                feedId: feedId,
                unreadOnly: false,
                starredOnly: false,
                keepEntryId: nil,
                searchText: nil
            )
        )

        try await store.markStarred(entryId: unstarredEntryId, isStarred: true)

        let inMemoryStarred = store.entries.first(where: { $0.id == unstarredEntryId })?.isStarred
        #expect(inMemoryStarred == true)

        let dbStarred = try await manager.read { db in
            try Bool.fetchOne(db, sql: "SELECT isStarred FROM entry WHERE id = ?", arguments: [unstarredEntryId])
        }
        #expect(dbStarred == true)
    }

    @Test("Unstarring in starredOnly query evicts row immediately")
    @MainActor
    func unstarEvictsInStarredOnlyQuery() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let manager = try DatabaseManager(path: dbPath)
        let (feedId, starredEntryId, _) = try await seedTwoEntries(database: manager)
        let store = EntryStore(db: manager)

        _ = await store.loadFirstPage(
            query: EntryStore.EntryListQuery(
                feedId: feedId,
                unreadOnly: false,
                starredOnly: true,
                keepEntryId: nil,
                searchText: nil
            )
        )
        #expect(store.entries.count == 1)

        try await store.markStarred(entryId: starredEntryId, isStarred: false)

        #expect(store.entries.isEmpty)
    }

    @Test("markStarred write failure keeps in-memory state unchanged")
    @MainActor
    func markStarredFailureKeepsInMemoryState() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let writableManager = try DatabaseManager(path: dbPath)
        let (feedId, _, unstarredEntryId) = try await seedTwoEntries(database: writableManager)

        let readonlyManager = try DatabaseManager(path: dbPath, accessMode: .readOnly)
        let store = EntryStore(db: readonlyManager)

        _ = await store.loadFirstPage(
            query: EntryStore.EntryListQuery(
                feedId: feedId,
                unreadOnly: false,
                starredOnly: false,
                keepEntryId: nil,
                searchText: nil
            )
        )

        let before = store.entries.first(where: { $0.id == unstarredEntryId })?.isStarred

        await #expect(throws: Error.self) {
            try await store.markStarred(entryId: unstarredEntryId, isStarred: true)
        }

        let after = store.entries.first(where: { $0.id == unstarredEntryId })?.isStarred
        #expect(before == false)
        #expect(after == before)
    }

    private func seedTwoEntries(database: DatabaseManager) async throws -> (feedId: Int64, starredEntryId: Int64, unstarredEntryId: Int64) {
        let feedId = try await insertFeed(database: database)
        return try await database.write { db in
            var starred = Entry(
                id: nil,
                feedId: feedId,
                guid: "starred-\(UUID().uuidString)",
                url: "https://example.com/starred",
                title: "Starred Entry",
                author: nil,
                publishedAt: Date().addingTimeInterval(2),
                summary: "starred",
                isRead: false,
                isStarred: true,
                createdAt: Date().addingTimeInterval(2)
            )
            try starred.insert(db)
            guard let starredEntryId = starred.id else {
                throw TestError.missingEntryID
            }

            var unstarred = Entry(
                id: nil,
                feedId: feedId,
                guid: "unstarred-\(UUID().uuidString)",
                url: "https://example.com/unstarred",
                title: "Unstarred Entry",
                author: nil,
                publishedAt: Date().addingTimeInterval(1),
                summary: "unstarred",
                isRead: false,
                isStarred: false,
                createdAt: Date().addingTimeInterval(1)
            )
            try unstarred.insert(db)
            guard let unstarredEntryId = unstarred.id else {
                throw TestError.missingEntryID
            }

            return (feedId, starredEntryId, unstarredEntryId)
        }
    }

    private func insertFeed(database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "Test Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                unreadCount: 0,
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

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-entry-store-starred-tests-\(UUID().uuidString).sqlite")
            .path
    }

    private enum TestError: Error {
        case missingFeedID
        case missingEntryID
    }
}
