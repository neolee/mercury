import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tags Database")
struct TagsDatabaseTests {
    @Test("Migration creates tag tables and indexes")
    @MainActor
    func migrationCreatesTagTablesAndIndexes() throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let manager = try DatabaseManager(path: dbPath)

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

    @Test("Entry tags association fetches assigned tags")
    @MainActor
    func entryTagsAssociationFetchesAssignedTags() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let manager = try DatabaseManager(path: dbPath)
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

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-tags-database-tests-\(UUID().uuidString).sqlite")
            .path
    }

    private enum TestError: Error {
        case missingFeedID
        case missingEntryID
        case missingTagID
    }
}
