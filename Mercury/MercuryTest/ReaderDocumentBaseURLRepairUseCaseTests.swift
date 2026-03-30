import Foundation
import GRDB
import XCTest
@testable import Mercury

final class ReaderDocumentBaseURLRepairUseCaseTests: XCTestCase {
    @MainActor
    func test_repairIfNeeded_backfillsTrustedBaseHrefFromStoredHTML() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderDocumentBaseURLRepairCredentialStore()
        ) { harness in
            let (entry, content) = try await Self.makeEntryAndContent(
                appModel: harness.appModel,
                entryURL: "https://example.com/posts/article",
                sourceHTML: """
                <html>
                  <head><base href="https://example.com/posts/article/"></head>
                  <body><img src="media/header.png"></body>
                </html>
                """,
                readabilityVersion: ReaderPipelineVersion.readability
            )
            let useCase = ReaderDocumentBaseURLRepairUseCase(
                contentStore: harness.appModel.contentStore,
                prepareArticleURL: { _, _ in
                    XCTFail("Stored trusted <base href> should avoid network preparation")
                    return nil
                },
                sourceDocumentFetcher: { _, _ in
                    XCTFail("Stored trusted <base href> should avoid network fetch")
                    return ReaderFetchedDocument(html: "", responseURL: nil)
                }
            )

            let repaired = try await useCase.repairIfNeeded(for: entry)
            let reloadedContent = try await harness.appModel.contentStore.content(for: content.entryId)

            XCTAssertTrue(repaired)
            XCTAssertEqual(reloadedContent?.documentBaseURL, "https://example.com/posts/article/")
            XCTAssertNil(reloadedContent?.readabilityVersion)
        }
    }

    @MainActor
    func test_repairIfNeeded_refetchesDocumentWhenStoredHTMLHasNoTrustedBase() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderDocumentBaseURLRepairCredentialStore()
        ) { harness in
            let (entry, content) = try await Self.makeEntryAndContent(
                appModel: harness.appModel,
                entryURL: "https://example.com/posts/article",
                sourceHTML: "<html><body>Hello</body></html>",
                readabilityVersion: ReaderPipelineVersion.readability
            )
            let useCase = ReaderDocumentBaseURLRepairUseCase(
                contentStore: harness.appModel.contentStore,
                prepareArticleURL: { _, _ in
                    ReaderArticleURLPreparation(
                        url: URL(string: "https://example.com/posts/article")!,
                        didUpgradeEntryURL: false
                    )
                },
                sourceDocumentFetcher: { _, _ in
                    ReaderFetchedDocument(
                        html: "<html><body>Fresh</body></html>",
                        responseURL: URL(string: "https://example.com/posts/article/")!
                    )
                }
            )

            let repaired = try await useCase.repairIfNeeded(for: entry)
            let reloadedContent = try await harness.appModel.contentStore.content(for: content.entryId)

            XCTAssertTrue(repaired)
            XCTAssertEqual(reloadedContent?.html, "<html><body>Fresh</body></html>")
            XCTAssertEqual(reloadedContent?.documentBaseURL, "https://example.com/posts/article/")
            XCTAssertNil(reloadedContent?.readabilityVersion)
        }
    }
}

private final class ReaderDocumentBaseURLRepairCredentialStore: CredentialStore, @unchecked Sendable {
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

private extension ReaderDocumentBaseURLRepairUseCaseTests {
    @MainActor
    static func makeEntryAndContent(
        appModel: AppModel,
        entryURL: String,
        sourceHTML: String,
        readabilityVersion: Int?
    ) async throws -> (Entry, Content) {
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
                url: entryURL,
                title: "Title",
                author: nil,
                publishedAt: nil,
                summary: "Summary",
                isRead: false,
                isStarred: false,
                createdAt: Date()
            )
            try entry.insert(db)

            var content = Content(
                id: nil,
                entryId: entry.id!,
                html: sourceHTML,
                cleanedHtml: "<p>Cleaned</p>",
                readabilityTitle: "Title",
                readabilityByline: nil,
                readabilityVersion: readabilityVersion,
                markdown: "# Title",
                markdownVersion: ReaderPipelineVersion.markdown,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date()
            )
            try content.insert(db)
            return (entry, content)
        }
    }
}
