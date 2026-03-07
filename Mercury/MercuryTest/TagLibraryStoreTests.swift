import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tag Library Store")
struct TagLibraryStoreTests {
    @Test("Tag library list includes alias counts and alias search matches canonical tag")
    @MainActor
    func listItemsIncludeAliasCountsAndSearchAliases() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = TagLibraryStore(db: database)

            let swiftTagId = try await insertTag(
                database: database,
                name: "Swift",
                isProvisional: false,
                usageCount: 4
            )
            _ = try await insertTag(
                database: database,
                name: "Draft Topic",
                isProvisional: true,
                usageCount: 0
            )
            try await insertAlias(database: database, tagId: swiftTagId, alias: "SwiftLang")
            try await insertAlias(database: database, tagId: swiftTagId, alias: "Swift Language")

            let allItems = await store.fetchTagLibraryItems(filter: .all)
            let swiftItem = try #require(allItems.first(where: { $0.tagId == swiftTagId }))
            #expect(swiftItem.aliasCount == 2)
            #expect(swiftItem.usageCount == 4)
            #expect(swiftItem.isProvisional == false)

            let provisionalItems = await store.fetchTagLibraryItems(filter: .provisional)
            #expect(provisionalItems.count == 1)
            #expect(provisionalItems.first?.isProvisional == true)

            let aliasSearchItems = await store.fetchTagLibraryItems(filter: .all, searchText: "SwiftLang")
            #expect(aliasSearchItems.map(\.tagId) == [swiftTagId])
        }
    }

    @Test("Inspector snapshot loads aliases and reflects batch mutation availability")
    @MainActor
    func inspectorSnapshotLoadsAliasesAndMutationAvailability() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = TagLibraryStore(db: database)
            let tagId = try await insertTag(
                database: database,
                name: "Machine Learning",
                isProvisional: false,
                usageCount: 3
            )
            try await insertAlias(database: database, tagId: tagId, alias: "ML")

            let initialSnapshot = try #require(await store.loadInspectorSnapshot(tagId: tagId))
            #expect(initialSnapshot.tagId == tagId)
            #expect(initialSnapshot.aliases.map(\.alias) == ["ML"])
            #expect(initialSnapshot.isMutationAllowed == true)

            try await insertBatchRun(database: database, status: .running)

            let blockedSnapshot = try #require(await store.loadInspectorSnapshot(tagId: tagId))
            #expect(blockedSnapshot.isMutationAllowed == false)
        }
    }

    @Test("Potential duplicates are surfaced conservatively in list and inspector")
    @MainActor
    func potentialDuplicatesAppearInListAndInspector() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = TagLibraryStore(db: database)

            let databaseTagID = try await insertTag(
                database: database,
                name: "Database",
                isProvisional: false,
                usageCount: 4
            )
            let databasesTagID = try await insertTag(
                database: database,
                name: "Databases",
                isProvisional: false,
                usageCount: 2
            )
            let pythonTagID = try await insertTag(
                database: database,
                name: "Python",
                isProvisional: false,
                usageCount: 5
            )
            let pytohnTagID = try await insertTag(
                database: database,
                name: "Pytohn",
                isProvisional: true,
                usageCount: 1
            )
            let macOSTagID = try await insertTag(
                database: database,
                name: "MacOS",
                isProvisional: false,
                usageCount: 3
            )
            let macOSTwoTagID = try await insertTag(
                database: database,
                name: "Mac OS",
                isProvisional: true,
                usageCount: 1
            )
            _ = try await insertTag(
                database: database,
                name: "AI",
                isProvisional: false,
                usageCount: 3
            )

            let duplicateListItems = await store.fetchTagLibraryItems(filter: .potentialDuplicates)
            let duplicateIDs = Set(duplicateListItems.map(\.tagId))
            #expect(
                duplicateIDs == Set([databaseTagID, databasesTagID, pythonTagID, pytohnTagID, macOSTagID, macOSTwoTagID])
            )

            let pythonSnapshot = try #require(await store.loadInspectorSnapshot(tagId: pythonTagID))
            let pythonCandidate = try #require(pythonSnapshot.potentialDuplicates.first(where: { $0.tagId == pytohnTagID }))
            #expect(pythonCandidate.reason == .nearSpellingVariant)

            let databaseSnapshot = try #require(await store.loadInspectorSnapshot(tagId: databaseTagID))
            let databaseCandidate = try #require(databaseSnapshot.potentialDuplicates.first(where: { $0.tagId == databasesTagID }))
            #expect(databaseCandidate.reason == .pluralizationVariant)

            let macOSSnapshot = try #require(await store.loadInspectorSnapshot(tagId: macOSTagID))
            let macOSCandidate = try #require(macOSSnapshot.potentialDuplicates.first(where: { $0.tagId == macOSTwoTagID }))
            #expect(macOSCandidate.reason == .likelyNamingVariant)
        }
    }

    @Test("Potential duplicates skip pairs already absorbed by aliases and weak similarities")
    @MainActor
    func potentialDuplicatesSkipAliasAbsorbedPairsAndWeakMatches() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = TagLibraryStore(db: database)

            let javascriptTagID = try await insertTag(
                database: database,
                name: "JavaScript",
                isProvisional: false,
                usageCount: 4
            )
            let javaScriptTagID = try await insertTag(
                database: database,
                name: "Java Script",
                isProvisional: false,
                usageCount: 2
            )
            let goTagID = try await insertTag(
                database: database,
                name: "Go",
                isProvisional: false,
                usageCount: 2
            )
            let gooTagID = try await insertTag(
                database: database,
                name: "Goo",
                isProvisional: false,
                usageCount: 1
            )
            try await insertAlias(database: database, tagId: javascriptTagID, alias: "Java Script")

            let duplicateListItems = await store.fetchTagLibraryItems(filter: .potentialDuplicates)
            let duplicateIDs = Set(duplicateListItems.map(\.tagId))
            #expect(duplicateIDs.contains(javascriptTagID) == false)
            #expect(duplicateIDs.contains(javaScriptTagID) == false)
            #expect(duplicateIDs.contains(goTagID) == false)
            #expect(duplicateIDs.contains(gooTagID) == false)

            let javaScriptSnapshot = try #require(await store.loadInspectorSnapshot(tagId: javaScriptTagID))
            #expect(javaScriptSnapshot.potentialDuplicates.isEmpty)
        }
    }

    @Test("Alias add and delete enforce deterministic collision validation")
    @MainActor
    func aliasAddAndDeleteValidateCollisions() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = TagLibraryStore(db: database)
            let swiftTagID = try await insertTag(
                database: database,
                name: "Swift",
                isProvisional: false,
                usageCount: 3
            )
            let rustTagID = try await insertTag(
                database: database,
                name: "Rust",
                isProvisional: false,
                usageCount: 2
            )
            try await insertAlias(database: database, tagId: swiftTagID, alias: "SwiftLang")

            try await store.addAlias(tagId: swiftTagID, alias: "Swift UI")

            let afterAddSnapshot = try #require(await store.loadInspectorSnapshot(tagId: swiftTagID))
            #expect(afterAddSnapshot.aliases.map(\.alias) == ["Swift UI", "SwiftLang"])

            await #expect(throws: TagMutationError.aliasMatchesCanonicalName) {
                try await store.addAlias(tagId: swiftTagID, alias: "swift")
            }

            await #expect(throws: TagMutationError.aliasAlreadyExists) {
                try await store.addAlias(tagId: rustTagID, alias: "SwiftLang")
            }

            await #expect(throws: TagMutationError.nameAlreadyExists) {
                try await store.addAlias(tagId: swiftTagID, alias: "Rust")
            }

            let addedAliasID = try #require(
                await fetchAliasID(
                    database: database,
                    tagId: swiftTagID,
                    normalizedAlias: TagNormalization.normalize("Swift UI")
                )
            )
            try await store.deleteAlias(id: addedAliasID)

            let afterDeleteSnapshot = try #require(await store.loadInspectorSnapshot(tagId: swiftTagID))
            #expect(afterDeleteSnapshot.aliases.map(\.alias) == ["SwiftLang"])
        }
    }

    @Test("Merge moves assignments, preserves safe aliases, and deletes source tag")
    @MainActor
    func mergeTagMovesAssignmentsAndSafeAliases() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = TagLibraryStore(db: database)
            let feedID = try await insertFeed(database: database)
            let entryOneID = try await insertEntry(database: database, feedId: feedID, title: "Entry One")
            let entryTwoID = try await insertEntry(database: database, feedId: feedID, title: "Entry Two")

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
                usageCount: 1
            )

            try await insertAlias(database: database, tagId: sourceTagID, alias: "Mac OS")
            try await insertAlias(database: database, tagId: sourceTagID, alias: "Apple Platforms")

            try await insertEntryTag(database: database, entryId: entryOneID, tagId: sourceTagID)
            try await insertEntryTag(database: database, entryId: entryTwoID, tagId: sourceTagID)
            try await insertEntryTag(database: database, entryId: entryTwoID, tagId: targetTagID)

            try await store.mergeTag(sourceID: sourceTagID, targetID: targetTagID)

            let sourceTag = try await fetchTag(database: database, id: sourceTagID)
            #expect(sourceTag == nil)

            let targetTag = try #require(try await fetchTag(database: database, id: targetTagID))
            #expect(targetTag.usageCount == 2)
            #expect(targetTag.isProvisional == false)

            let entryTwoAssignments = try await fetchEntryTags(database: database, entryId: entryTwoID)
            #expect(entryTwoAssignments.filter { $0.tagId == targetTagID }.count == 1)

            let targetAliases = try await fetchAliases(database: database, tagId: targetTagID)
            #expect(targetAliases.map(\.alias) == ["Mac OS", "MacOS"])
            #expect(targetAliases.map(\.normalizedAlias) == ["mac os", "macos"])

            let sourceAliases = try await fetchAliases(database: database, tagId: sourceTagID)
            #expect(sourceAliases.isEmpty)

            let entryOneAssignments = try await fetchEntryTags(database: database, entryId: entryOneID)
            #expect(entryOneAssignments.map(\.tagId) == [targetTagID])
        }
    }

    @Test("Merge preview reports alias preservation and skipped conflicts")
    @MainActor
    func mergePreviewReportsAliasTransferBehavior() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = TagLibraryStore(db: database)

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
                usageCount: 4
            )
            _ = try await insertTag(
                database: database,
                name: "Mac Setup",
                isProvisional: false,
                usageCount: 1
            )

            try await insertAlias(database: database, tagId: sourceTagID, alias: "Mac OS")
            try await insertAlias(database: database, tagId: sourceTagID, alias: "Mac Setup")

            let preview = try await store.loadMergePreview(
                sourceID: sourceTagID,
                targetID: targetTagID
            )

            #expect(preview.sourceTagId == sourceTagID)
            #expect(preview.targetTagId == targetTagID)
            #expect(preview.willPreserveSourceCanonicalAsAlias == true)
            #expect(preview.migratedAliasCount == 1)
            #expect(preview.skippedAliasCount == 1)
        }
    }

    @Test("Make permanent, delete unused, and single delete follow tag library semantics")
    @MainActor
    func makePermanentDeleteUnusedAndDeleteSingleTag() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let store = TagLibraryStore(db: database)
            let feedID = try await insertFeed(database: database)
            let entryID = try await insertEntry(database: database, feedId: feedID, title: "Delete Me")

            let provisionalTagID = try await insertTag(
                database: database,
                name: "Draft Topic",
                isProvisional: true,
                usageCount: 0
            )
            let unusedTagID = try await insertTag(
                database: database,
                name: "Unused",
                isProvisional: true,
                usageCount: 0
            )
            let usedTagID = try await insertTag(
                database: database,
                name: "Active Topic",
                isProvisional: false,
                usageCount: 1
            )
            try await insertAlias(database: database, tagId: unusedTagID, alias: "No Longer Needed")
            try await insertAlias(database: database, tagId: usedTagID, alias: "Delete Alias")
            try await insertEntryTag(database: database, entryId: entryID, tagId: usedTagID)

            try await store.makeTagPermanent(id: provisionalTagID)
            let promotedTag = try #require(try await fetchTag(database: database, id: provisionalTagID))
            #expect(promotedTag.isProvisional == false)

            let deletedUnusedCount = try await store.deleteUnusedTags()
            #expect(deletedUnusedCount == 2)
            #expect(try await fetchTag(database: database, id: provisionalTagID) == nil)
            #expect(try await fetchTag(database: database, id: unusedTagID) == nil)

            try await store.deleteTag(id: usedTagID)
            #expect(try await fetchTag(database: database, id: usedTagID) == nil)
            #expect(try await fetchAliases(database: database, tagId: usedTagID).isEmpty)
            #expect(try await fetchEntryTags(database: database, entryId: entryID).isEmpty)
        }
    }

    @Test("Active batch lifecycle blocks all tag library mutations")
    @MainActor
    func activeBatchLifecycleBlocksTagLibraryMutations() async throws {
        for status in TagBatchRunStatus.activeLifecycleStatuses {
            try await InMemoryDatabaseFixture.withFixture { fixture in
                let database = fixture.database
                let store = TagLibraryStore(db: database)
                let sourceTagID = try await insertTag(
                    database: database,
                    name: "Source",
                    isProvisional: true,
                    usageCount: 1
                )
                let targetTagID = try await insertTag(
                    database: database,
                    name: "Target",
                    isProvisional: true,
                    usageCount: 1
                )
                try await insertAlias(database: database, tagId: sourceTagID, alias: "Source Alias")
                let aliasID = try #require(
                    await fetchAliasID(
                        database: database,
                        tagId: sourceTagID,
                        normalizedAlias: TagNormalization.normalize("Source Alias")
                    )
                )
                try await insertBatchRun(database: database, status: status)

                await #expect(throws: TagMutationError.batchRunActive) {
                    try await store.addAlias(tagId: sourceTagID, alias: "Another Alias")
                }
                await #expect(throws: TagMutationError.batchRunActive) {
                    try await store.deleteAlias(id: aliasID)
                }
                await #expect(throws: TagMutationError.batchRunActive) {
                    try await store.makeTagPermanent(id: sourceTagID)
                }
                await #expect(throws: TagMutationError.batchRunActive) {
                    _ = try await store.deleteUnusedTags()
                }
                await #expect(throws: TagMutationError.batchRunActive) {
                    try await store.deleteTag(id: sourceTagID)
                }
                await #expect(throws: TagMutationError.batchRunActive) {
                    try await store.mergeTag(sourceID: sourceTagID, targetID: targetTagID)
                }
            }
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
            guard let tagId = tag.id else {
                throw TestError.missingTagID
            }
            return tagId
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
            guard let feedID = feed.id else {
                throw TestError.missingFeedID
            }
            return feedID
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
            guard let entryID = entry.id else {
                throw TestError.missingEntryID
            }
            return entryID
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

    private func insertEntryTag(database: DatabaseManager, entryId: Int64, tagId: Int64) async throws {
        try await database.write { db in
            var row = Mercury.EntryTag(entryId: entryId, tagId: tagId, source: "manual", confidence: nil)
            try row.insert(db)
        }
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
                .order(Column("normalizedAlias").asc)
                .fetchAll(db)
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

    private func fetchEntryTags(database: DatabaseManager, entryId: Int64) async throws -> [Mercury.EntryTag] {
        try await database.read { db in
            try Mercury.EntryTag
                .filter(Column("entryId") == entryId)
                .order(Column("tagId").asc)
                .fetchAll(db)
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
