import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tag Assignment")
struct TagAssignmentTests {
    @Test("assignTags deduplicates normalized names and accumulates usage")
    @MainActor
    func assignTagsDeduplicatesAndAccumulatesUsage() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let manager = try DatabaseManager(path: dbPath)
        let store = EntryStore(db: manager)

        let feedId = try await insertFeed(database: manager)
        let firstEntryId = try await insertEntry(database: manager, feedId: feedId, title: "Entry 1")
        let secondEntryId = try await insertEntry(database: manager, feedId: feedId, title: "Entry 2")

        try await store.assignTags(to: firstEntryId, names: [" AI ", "ai", "AI"], source: "manual")

        try await manager.read { db in
            let tagCount = try Tag.fetchCount(db)
            #expect(tagCount == 1)

            guard let storedTag = try Tag.fetchOne(db) else {
                throw TestError.missingTag
            }
            #expect(storedTag.normalizedName == "ai")
            #expect(storedTag.usageCount == 1)
            #expect(storedTag.isProvisional == true)

            let firstEntryTagCount = try EntryTag.filter(Column("entryId") == firstEntryId).fetchCount(db)
            #expect(firstEntryTagCount == 1)
        }

        try await store.assignTags(to: secondEntryId, names: ["ai"], source: "rss")
        try await store.assignTags(to: secondEntryId, names: ["AI"], source: "manual")

        try await manager.read { db in
            guard let storedTag = try Tag.fetchOne(db) else {
                throw TestError.missingTag
            }
            #expect(storedTag.usageCount == 2)
            #expect(storedTag.isProvisional == false)

            let allEntryTagRows = try EntryTag.fetchCount(db)
            #expect(allEntryTagRows == 2)
        }
    }

    private func insertFeed(database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "Tag Assign Feed",
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
                throw TestError.missingEntry
            }
            return entryId
        }
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-tag-assignment-tests-\(UUID().uuidString).sqlite")
            .path
    }

    private enum TestError: Error {
        case missingFeed
        case missingEntry
        case missingTag
    }
}
