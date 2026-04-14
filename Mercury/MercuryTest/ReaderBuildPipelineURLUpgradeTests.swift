import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Reader Build Pipeline URL Upgrade")
@MainActor
struct ReaderBuildPipelineURLUpgradeTests {

    @Test("Prepare article URL upgrades persisted HTTP entry URL to HTTPS")
    @MainActor
    func prepareArticleURLUpgradesPersistedHTTPEntryURLToHTTPS() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderBuildPipelineTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(
                appModel: appModel,
                url: "http://example.com/articles/upgraded"
            )

            let preparedURL = await appModel.readerBuildPipeline.prepareArticleURL(for: entry)

            #expect(preparedURL?.url.absoluteString == "https://example.com/articles/upgraded")
            #expect(preparedURL?.didUpgradeEntryURL == true)

            let entryId = try #require(entry.id)

            let reloadedEntry = await appModel.entryStore.loadEntry(id: entryId)
            #expect(reloadedEntry?.url == "https://example.com/articles/upgraded")
        }
    }

    @Test("Prepare article URL keeps preferred URL when persistence conflicts")
    @MainActor
    func prepareArticleURLKeepsPreferredURLWhenPersistenceConflicts() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderBuildPipelineTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeConflictingEntries(appModel: appModel)

            let preparedURL = await appModel.readerBuildPipeline.prepareArticleURL(for: entry)

            #expect(preparedURL?.url.absoluteString == "https://example.com/articles/conflict")
            #expect(preparedURL?.didUpgradeEntryURL == false)

            let entryId = try #require(entry.id)

            let reloadedEntry = await appModel.entryStore.loadEntry(id: entryId)
            #expect(reloadedEntry?.url == "http://example.com/articles/conflict")
        }
    }
}

private extension ReaderBuildPipelineURLUpgradeTests {
    @MainActor
    static func makeEntry(appModel: AppModel, url: String) async throws -> Entry {
        try await appModel.database.write { db in
            var feed = Feed(
                id: nil,
                title: "Test Feed",
                feedURL: "https://example.com/feed/\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)

            var entry = Entry(
                id: nil,
                feedId: feed.id!,
                guid: UUID().uuidString,
                url: url,
                title: "Title",
                author: nil,
                publishedAt: nil,
                summary: "Summary",
                isRead: false,
                isStarred: false,
                createdAt: Date()
            )
            try entry.insert(db)
            return entry
        }
    }

    @MainActor
    static func makeConflictingEntries(appModel: AppModel) async throws -> Entry {
        try await appModel.database.write { db in
            var feed = Feed(
                id: nil,
                title: "Test Feed",
                feedURL: "https://example.com/feed/\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)

            var httpEntry = Entry(
                id: nil,
                feedId: feed.id!,
                guid: UUID().uuidString,
                url: "http://example.com/articles/conflict",
                title: "HTTP Title",
                author: nil,
                publishedAt: nil,
                summary: "Summary",
                isRead: false,
                isStarred: false,
                createdAt: Date()
            )
            try httpEntry.insert(db)

            var httpsEntry = Entry(
                id: nil,
                feedId: feed.id!,
                guid: UUID().uuidString,
                url: "https://example.com/articles/conflict",
                title: "HTTPS Title",
                author: nil,
                publishedAt: nil,
                summary: "Summary",
                isRead: false,
                isStarred: false,
                createdAt: Date()
            )
            try httpsEntry.insert(db)

            return httpEntry
        }
    }
}

private final class ReaderBuildPipelineTestCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func save(secret: String, for ref: String) throws {
        storage[ref] = secret
    }

    func readSecret(for ref: String) throws -> String {
        guard let secret = storage[ref] else {
            throw CredentialStoreError.itemNotFound
        }
        return secret
    }

    func deleteSecret(for ref: String) throws {
        storage.removeValue(forKey: ref)
    }
}
