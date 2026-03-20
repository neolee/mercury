import Foundation
import GRDB
import XCTest
@testable import Mercury

final class AppModelReaderRuntimeTests: XCTestCase {

    @MainActor
    func test_availableReaderMarkdown_requiresCurrentReadabilityAndMarkdownVersions() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            guard let entryId = entry.id else {
                XCTFail("Missing entry ID")
                return
            }

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)
            let currentMarkdown = try await appModel.availableReaderMarkdown(entryId: entryId)
            XCTAssertEqual(currentMarkdown, "# Title\n\nBody")

            try await appModel.contentStore.invalidateReaderPipeline(entryId: entryId, target: .readability)
            let staleReadabilityMarkdown = try await appModel.availableReaderMarkdown(entryId: entryId)
            XCTAssertNil(staleReadabilityMarkdown)

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)
            try await appModel.contentStore.invalidateReaderPipeline(entryId: entryId, target: .markdown)
            let staleMarkdown = try await appModel.availableReaderMarkdown(entryId: entryId)
            XCTAssertNil(staleMarkdown)
        }
    }

    @MainActor
    func test_availableReaderMarkdown_returnsNilWhileEntryIsMarkedRebuilding() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            guard let entryId = entry.id else {
                XCTFail("Missing entry ID")
                return
            }

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)

            let scopeStarted = expectation(description: "scope-started")
            var continuation: CheckedContinuation<Void, Never>?
            let task = Task { @MainActor in
                await appModel.withReaderPipelineRebuildScope(entryId: entryId) {
                    scopeStarted.fulfill()
                    await withCheckedContinuation { continuation = $0 }
                }
            }

            await fulfillment(of: [scopeStarted], timeout: 1)

            XCTAssertTrue(appModel.isReaderPipelineRebuilding(entryId: entryId))
            let markdownWhileRebuilding = try await appModel.availableReaderMarkdown(entryId: entryId)
            XCTAssertNil(markdownWhileRebuilding)

            continuation?.resume()
            await task.value

            XCTAssertFalse(appModel.isReaderPipelineRebuilding(entryId: entryId))
        }
    }

    @MainActor
    func test_nestedReaderPipelineRebuildScope_keepsStateUntilOuterScopeFinishes() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            guard let entryId = entry.id else {
                XCTFail("Missing entry ID")
                return
            }

            let outerPause = expectation(description: "outer-pause")
            var continuation: CheckedContinuation<Void, Never>?
            let task = Task { @MainActor in
                await appModel.withReaderPipelineRebuildScope(entryId: entryId) {
                    XCTAssertTrue(appModel.isReaderPipelineRebuilding(entryId: entryId))
                    await appModel.withReaderPipelineRebuildScope(entryId: entryId) {
                        XCTAssertTrue(appModel.isReaderPipelineRebuilding(entryId: entryId))
                    }
                    XCTAssertTrue(appModel.isReaderPipelineRebuilding(entryId: entryId))
                    outerPause.fulfill()
                    await withCheckedContinuation { continuation = $0 }
                }
            }

            await fulfillment(of: [outerPause], timeout: 1)
            XCTAssertTrue(appModel.isReaderPipelineRebuilding(entryId: entryId))

            continuation?.resume()
            await task.value

            XCTAssertFalse(appModel.isReaderPipelineRebuilding(entryId: entryId))
        }
    }

    @MainActor
    func test_rerunReaderPipeline_readerHTML_rebuildsAndClearsRebuildState() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            guard let entryId = entry.id else {
                XCTFail("Missing entry ID")
                return
            }

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)

            let theme = ReaderThemeResolver.resolve(
                presetID: .classic,
                mode: .forceLight,
                isSystemDark: false,
                override: nil
            )

            let result = await appModel.rerunReaderPipeline(
                for: entry,
                theme: theme,
                target: .readerHTML
            )

            XCTAssertFalse(appModel.isReaderPipelineRebuilding(entryId: entryId))
            XCTAssertNil(result.errorMessage)
            XCTAssertNotNil(result.html)

            let cache = try await appModel.contentStore.cachedHTML(
                for: entryId,
                themeId: theme.cacheThemeID
            )
            XCTAssertEqual(cache?.readerRenderVersion, ReaderPipelineVersion.readerRender)
            XCTAssertNotNil(cache?.html)
        }
    }

    @MainActor
    func test_taggingSourceBody_fallsBackToEntrySummaryWhenMarkdownIsStale() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            guard let entryId = entry.id else {
                XCTFail("Missing entry ID")
                return
            }

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)
            let currentBody = try await appModel.taggingSourceBody(entry: entry, maxLength: 8)
            XCTAssertEqual(currentBody, "# Title\n")

            try await appModel.contentStore.invalidateReaderPipeline(entryId: entryId, target: .readability)
            let fallbackBody = try await appModel.taggingSourceBody(entry: entry, maxLength: 800)
            XCTAssertEqual(fallbackBody, "Fallback summary")
        }
    }
}

private extension AppModelReaderRuntimeTests {
    @MainActor
    static func makeEntry(appModel: AppModel, summary: String) async throws -> Entry {
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
                url: "https://example.com/articles/\(UUID().uuidString)",
                title: "Title",
                author: nil,
                publishedAt: nil,
                summary: summary,
                isRead: false,
                isStarred: false,
                createdAt: Date()
            )
            try entry.insert(db)
            return entry
        }
    }

    @MainActor
    static func seedCurrentReaderPipeline(appModel: AppModel, entryId: Int64) async throws {
        let content = Content(
            id: nil,
            entryId: entryId,
            html: "<html>source</html>",
            cleanedHtml: "<p>Body</p>",
            readabilityTitle: "Title",
            readabilityByline: nil,
            readabilityVersion: ReaderPipelineVersion.readability,
            markdown: "# Title\n\nBody",
            markdownVersion: ReaderPipelineVersion.markdown,
            displayMode: ContentDisplayMode.cleaned.rawValue,
            createdAt: Date()
        )

        _ = try await appModel.contentStore.upsert(content)
        try await appModel.contentStore.upsertCache(
            entryId: entryId,
            themeId: "default",
            html: "<html>rendered</html>",
            readerRenderVersion: ReaderPipelineVersion.readerRender
        )
    }
}

private final class ReaderRuntimeTestCredentialStore: CredentialStore, @unchecked Sendable {
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
