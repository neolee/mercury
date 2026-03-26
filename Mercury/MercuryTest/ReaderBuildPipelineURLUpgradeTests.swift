import Foundation
import GRDB
import XCTest
@testable import Mercury

final class ReaderBuildPipelineURLUpgradeTests: XCTestCase {

    @MainActor
    func test_prepareArticleURL_upgradesPersistedHTTPEntryURLToHTTPS() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderBuildPipelineTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(
                appModel: appModel,
                url: "http://example.com/articles/upgraded"
            )

            let preparedURL = await appModel.readerBuildPipeline.prepareArticleURL(for: entry)

            XCTAssertEqual(preparedURL?.url.absoluteString, "https://example.com/articles/upgraded")
            XCTAssertEqual(preparedURL?.didUpgradeEntryURL, true)

            guard let entryId = entry.id else {
                XCTFail("Missing entry ID")
                return
            }

            let reloadedEntry = await appModel.entryStore.loadEntry(id: entryId)
            XCTAssertEqual(reloadedEntry?.url, "https://example.com/articles/upgraded")
        }
    }

    @MainActor
    func test_prepareArticleURL_keepsPreferredURLWhenPersistenceConflicts() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderBuildPipelineTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeConflictingEntries(appModel: appModel)

            let preparedURL = await appModel.readerBuildPipeline.prepareArticleURL(for: entry)

            XCTAssertEqual(preparedURL?.url.absoluteString, "https://example.com/articles/conflict")
            XCTAssertEqual(preparedURL?.didUpgradeEntryURL, false)

            guard let entryId = entry.id else {
                XCTFail("Missing entry ID")
                return
            }

            let reloadedEntry = await appModel.entryStore.loadEntry(id: entryId)
            XCTAssertEqual(reloadedEntry?.url, "http://example.com/articles/conflict")
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
