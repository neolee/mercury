import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("AppModel Visible Entry Counts")
@MainActor
struct AppModelVisibleEntryCountTests {
    @Test("refreshCounts excludes tombstoned entries from entryCount")
    @MainActor
    func refreshCountsExcludesTombstonedEntries() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: AppModelVisibleEntryCountTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database

            let feedId = try await database.write { db in
                var feed = Feed(
                    id: nil,
                    title: "Feed",
                    feedURL: "https://example.com/feed-\(UUID().uuidString)",
                    siteURL: "https://example.com",
                    lastFetchedAt: nil,
                    createdAt: Date()
                )
                try feed.insert(db)
                return try #require(feed.id)
            }

            let deletedEntryId = try await database.write { db in
                var visibleEntry = Entry(
                    id: nil,
                    feedId: feedId,
                    guid: "visible-\(UUID().uuidString)",
                    url: "https://example.com/visible",
                    title: "Visible",
                    author: nil,
                    publishedAt: Date(),
                    summary: "Visible",
                    isRead: false,
                    isStarred: false,
                    createdAt: Date()
                )
                try visibleEntry.insert(db)

                var deletedEntry = Entry(
                    id: nil,
                    feedId: feedId,
                    guid: "deleted-\(UUID().uuidString)",
                    url: "https://example.com/deleted",
                    title: "Deleted",
                    author: nil,
                    publishedAt: Date(),
                    summary: "Deleted",
                    isRead: false,
                    isStarred: false,
                    createdAt: Date()
                )
                try deletedEntry.insert(db)
                return try #require(deletedEntry.id)
            }

            try await database.write { db in
                _ = try Entry
                    .filter(Column("id") == deletedEntryId)
                    .updateAll(db, Column("isDeleted").set(to: true))
            }

            await appModel.refreshCounts()

            #expect(appModel.feedCount == 1)
            #expect(appModel.entryCount == 1)
        }
    }
}

private final class AppModelVisibleEntryCountTestCredentialStore: CredentialStore, @unchecked Sendable {
    func save(secret: String, for ref: String) throws {
    }

    func readSecret(for ref: String) throws -> String {
        throw CredentialStoreError.itemNotFound
    }

    func deleteSecret(for ref: String) throws {
    }
}
