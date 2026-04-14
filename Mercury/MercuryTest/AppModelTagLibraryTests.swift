import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("AppModel Tag Library")
@MainActor
struct AppModelTagLibraryTests {
    @Test("AppModel exposes tag library reads for list and inspector")
    @MainActor
    func loadsTagLibraryDataThroughAppModel() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagLibraryTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database

            let swiftTagID = try await insertTag(
                database: database,
                name: "Swift",
                isProvisional: false,
                usageCount: 3
            )
            _ = try await insertTag(
                database: database,
                name: "Draft Topic",
                isProvisional: true,
                usageCount: 0
            )
            try await insertAlias(database: database, tagId: swiftTagID, alias: "SwiftLang")

            let items = await appModel.loadTagLibraryItems(filter: .all, searchText: "SwiftLang")
            #expect(items.map(\.tagId) == [swiftTagID])

            let snapshot = try #require(await appModel.loadTagLibraryInspectorSnapshot(tagId: swiftTagID))
            #expect(snapshot.aliases.map(\.alias) == ["SwiftLang"])
        }
    }

    @Test("AppModel exposes merge preview for tag library confirmation flows")
    @MainActor
    func loadsMergePreviewThroughAppModel() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagLibraryTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database

            let sourceTagID = try await insertTag(
                database: database,
                name: "MacOS",
                isProvisional: false,
                usageCount: 2
            )
            let targetTagID = try await insertTag(
                database: database,
                name: "Apple Platforms",
                isProvisional: false,
                usageCount: 5
            )
            _ = try await insertTag(
                database: database,
                name: "Mac Setup",
                isProvisional: false,
                usageCount: 1
            )

            try await insertAlias(database: database, tagId: sourceTagID, alias: "Mac OS")
            try await insertAlias(database: database, tagId: sourceTagID, alias: "Mac Setup")

            let preview = try await appModel.loadTagLibraryMergePreview(
                sourceID: sourceTagID,
                targetID: targetTagID
            )

            #expect(preview.sourceTagId == sourceTagID)
            #expect(preview.targetTagId == targetTagID)
            #expect(preview.migratedAliasCount == 1)
            #expect(preview.skippedAliasCount == 1)
        }
    }

    @Test("AppModel tag library mutations increment tagMutationVersion")
    @MainActor
    func mutationsIncrementTagMutationVersion() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagLibraryTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database
            let feedID = try await insertFeed(database: database)
            let entryID = try await insertEntry(database: database, feedId: feedID, title: "Merge Me")

            let sourceTagID = try await insertTag(
                database: database,
                name: "MacOS",
                isProvisional: true,
                usageCount: 1
            )
            let targetTagID = try await insertTag(
                database: database,
                name: "Apple Platforms",
                isProvisional: true,
                usageCount: 0
            )
            try await insertEntryTag(database: database, entryId: entryID, tagId: sourceTagID)

            #expect(appModel.tagMutationVersion == 0)

            try await appModel.addTagLibraryAlias(tagId: sourceTagID, alias: "Mac OS")
            #expect(appModel.tagMutationVersion == 1)

            let aliasID = try #require(
                await fetchAliasID(
                    database: database,
                    tagId: sourceTagID,
                    normalizedAlias: TagNormalization.normalize("Mac OS")
                )
            )
            try await appModel.deleteTagLibraryAlias(id: aliasID)
            #expect(appModel.tagMutationVersion == 2)

            try await appModel.makeTagLibraryTagPermanent(id: sourceTagID)
            #expect(appModel.tagMutationVersion == 3)

            try await appModel.mergeTagLibraryTag(sourceID: sourceTagID, targetID: targetTagID)
            #expect(appModel.tagMutationVersion == 4)

            let unusedTagID = try await insertTag(
                database: database,
                name: "Unused",
                isProvisional: true,
                usageCount: 0
            )
            _ = unusedTagID
            let deletedUnusedCount = try await appModel.deleteUnusedTagLibraryTags()
            #expect(deletedUnusedCount == 1)
            #expect(appModel.tagMutationVersion == 5)

            try await appModel.deleteTagLibraryTag(id: targetTagID)
            #expect(appModel.tagMutationVersion == 6)
        }
    }

    @Test("Sidebar delete continues to use shared tag library deletion path")
    @MainActor
    func sidebarDeleteUsesSharedLibraryDeletion() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagLibraryTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database
            let feedID = try await insertFeed(database: database)
            let entryID = try await insertEntry(database: database, feedId: feedID, title: "Delete Me")
            let tagID = try await insertTag(
                database: database,
                name: "Active Topic",
                isProvisional: false,
                usageCount: 1
            )
            try await insertAlias(database: database, tagId: tagID, alias: "Delete Alias")
            try await insertEntryTag(database: database, entryId: entryID, tagId: tagID)

            await appModel.deleteTag(id: tagID)

            #expect(appModel.tagMutationVersion == 1)
            #expect(try await fetchTag(database: database, id: tagID) == nil)
            #expect(try await fetchAliases(database: database, tagId: tagID).isEmpty)
            #expect(try await fetchEntryTags(database: database, entryId: entryID).isEmpty)
        }
    }

    private func insertTag(
        database: DatabaseManager,
        name: String,
        isProvisional: Bool,
        usageCount: Int
    ) async throws -> Int64 {
        try await database.write { db in
            var tag = Mercury.Tag(
                id: nil,
                name: name,
                normalizedName: TagNormalization.normalize(name),
                isProvisional: isProvisional,
                usageCount: usageCount
            )
            try tag.insert(db)
            return try #require(tag.id)
        }
    }

    private func insertAlias(database: DatabaseManager, tagId: Int64, alias: String) async throws {
        try await database.write { db in
            var row = Mercury.TagAlias(
                id: nil,
                tagId: tagId,
                alias: alias,
                normalizedAlias: TagNormalization.normalize(alias)
            )
            try row.insert(db)
        }
    }

    private func insertFeed(database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Mercury.Feed(
                id: nil,
                title: "Tag Library Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            return try #require(feed.id)
        }
    }

    private func insertEntry(database: DatabaseManager, feedId: Int64, title: String) async throws -> Int64 {
        try await database.write { db in
            var entry = Mercury.Entry(
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
            return try #require(entry.id)
        }
    }

    private func insertEntryTag(database: DatabaseManager, entryId: Int64, tagId: Int64) async throws {
        try await database.write { db in
            var row = Mercury.EntryTag(entryId: entryId, tagId: tagId, source: "manual", confidence: nil)
            try row.insert(db)
        }
    }

    private func fetchAliasID(
        database: DatabaseManager,
        tagId: Int64,
        normalizedAlias: String
    ) async -> Int64? {
        try? await database.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT id
                FROM tag_alias
                WHERE tagId = ?
                  AND normalizedAlias = ?
                LIMIT 1
                """,
                arguments: [tagId, normalizedAlias]
            )
        } ?? nil
    }

    private func fetchTag(database: DatabaseManager, id: Int64) async throws -> Mercury.Tag? {
        try await database.read { db in
            try Mercury.Tag.fetchOne(db, key: id)
        }
    }

    private func fetchAliases(database: DatabaseManager, tagId: Int64) async throws -> [Mercury.TagAlias] {
        try await database.read { db in
            try Mercury.TagAlias
                .filter(Column("tagId") == tagId)
                .fetchAll(db)
        }
    }

    private func fetchEntryTags(database: DatabaseManager, entryId: Int64) async throws -> [Mercury.EntryTag] {
        try await database.read { db in
            try Mercury.EntryTag
                .filter(Column("entryId") == entryId)
                .fetchAll(db)
        }
    }
}

private final class TagLibraryTestCredentialStore: CredentialStore, @unchecked Sendable {
    func save(secret: String, for ref: String) throws {
    }

    func readSecret(for ref: String) throws -> String {
        throw CredentialStoreError.itemNotFound
    }

    func deleteSecret(for ref: String) throws {
    }
}
