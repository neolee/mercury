//
//  ReaderPipelineInvalidationTests.swift
//  MercuryTest
//

import XCTest
import GRDB
@testable import Mercury

final class ReaderPipelineInvalidationTests: XCTestCase {

    @MainActor
    func test_invalidateReaderHTML_marksAllThemeCachesStaleForEntryOnly() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let store = ContentStore(db: fixture.database)
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let otherEntryId = try await Self.makeTestEntry(db: fixture.database)

            try await seedCurrentReaderPipeline(store: store, entryId: entryId)
            try await store.upsertCache(
                entryId: entryId,
                themeId: "alternate",
                html: "<html>alternate</html>",
                readerRenderVersion: ReaderPipelineVersion.readerRender
            )
            try await seedCurrentReaderPipeline(store: store, entryId: otherEntryId)

            try await store.invalidateReaderPipeline(entryId: entryId, target: .readerHTML)

            let targetDefaultCache = try await store.cachedHTML(for: entryId, themeId: "default")
            let targetAlternateCache = try await store.cachedHTML(for: entryId, themeId: "alternate")
            let otherEntryCache = try await store.cachedHTML(for: otherEntryId, themeId: "default")
            let targetContent = try await store.content(for: entryId)

            XCTAssertNil(targetDefaultCache?.readerRenderVersion)
            XCTAssertNil(targetAlternateCache?.readerRenderVersion)
            XCTAssertEqual(otherEntryCache?.readerRenderVersion, ReaderPipelineVersion.readerRender)
            XCTAssertEqual(targetContent?.readabilityVersion, ReaderPipelineVersion.readability)
            XCTAssertEqual(targetContent?.markdownVersion, ReaderPipelineVersion.markdown)
        }
    }

    @MainActor
    func test_invalidateMarkdown_clearsMarkdownVersionOnly() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let store = ContentStore(db: fixture.database)
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let otherEntryId = try await Self.makeTestEntry(db: fixture.database)

            try await seedCurrentReaderPipeline(store: store, entryId: entryId)
            try await seedCurrentReaderPipeline(store: store, entryId: otherEntryId)

            try await store.invalidateReaderPipeline(entryId: entryId, target: .markdown)

            let targetContent = try await store.content(for: entryId)
            let otherContent = try await store.content(for: otherEntryId)
            let targetCache = try await store.cachedHTML(for: entryId, themeId: "default")

            XCTAssertNil(targetContent?.markdownVersion)
            XCTAssertEqual(targetContent?.readabilityVersion, ReaderPipelineVersion.readability)
            XCTAssertEqual(targetContent?.markdown, "# Title\n\nBody")
            XCTAssertEqual(targetCache?.readerRenderVersion, ReaderPipelineVersion.readerRender)
            XCTAssertEqual(otherContent?.markdownVersion, ReaderPipelineVersion.markdown)
        }
    }

    @MainActor
    func test_invalidateReadability_clearsReadabilityVersionOnly() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let store = ContentStore(db: fixture.database)
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let otherEntryId = try await Self.makeTestEntry(db: fixture.database)

            try await seedCurrentReaderPipeline(store: store, entryId: entryId)
            try await seedCurrentReaderPipeline(store: store, entryId: otherEntryId)

            try await store.invalidateReaderPipeline(entryId: entryId, target: .readability)

            let targetContent = try await store.content(for: entryId)
            let otherContent = try await store.content(for: otherEntryId)
            let targetCache = try await store.cachedHTML(for: entryId, themeId: "default")

            XCTAssertNil(targetContent?.readabilityVersion)
            XCTAssertEqual(targetContent?.markdownVersion, ReaderPipelineVersion.markdown)
            XCTAssertEqual(targetContent?.cleanedHtml, "<p>Body</p>")
            XCTAssertEqual(targetCache?.readerRenderVersion, ReaderPipelineVersion.readerRender)
            XCTAssertEqual(otherContent?.readabilityVersion, ReaderPipelineVersion.readability)
        }
    }

    @MainActor
    func test_invalidateAll_deletesContentAndAllCachesForEntryOnly() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let store = ContentStore(db: fixture.database)
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let otherEntryId = try await Self.makeTestEntry(db: fixture.database)

            try await seedCurrentReaderPipeline(store: store, entryId: entryId)
            try await store.upsertCache(
                entryId: entryId,
                themeId: "alternate",
                html: "<html>alternate</html>",
                readerRenderVersion: ReaderPipelineVersion.readerRender
            )
            try await seedCurrentReaderPipeline(store: store, entryId: otherEntryId)

            try await store.invalidateReaderPipeline(entryId: entryId, target: .all)

            let targetContent = try await store.content(for: entryId)
            let targetDefaultCache = try await store.cachedHTML(for: entryId, themeId: "default")
            let targetAlternateCache = try await store.cachedHTML(for: entryId, themeId: "alternate")
            let otherContent = try await store.content(for: otherEntryId)
            let otherCache = try await store.cachedHTML(for: otherEntryId, themeId: "default")

            XCTAssertNil(targetContent)
            XCTAssertNil(targetDefaultCache)
            XCTAssertNil(targetAlternateCache)
            XCTAssertNotNil(otherContent)
            XCTAssertNotNil(otherCache)
        }
    }
}

private extension ReaderPipelineInvalidationTests {
    @MainActor
    static func makeTestEntry(db: DatabaseManager) async throws -> Int64 {
        try await db.write { grdb in
            var feed = Feed(
                id: nil,
                title: "Test Feed",
                feedURL: "https://example.com/feed/\(UUID().uuidString)",
                siteURL: nil,
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(grdb)
            let feedId = feed.id!

            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: UUID().uuidString,
                url: "https://example.com/\(UUID().uuidString)",
                title: "Title",
                author: nil,
                publishedAt: nil,
                summary: nil,
                isRead: false,
                isStarred: false,
                createdAt: Date()
            )
            try entry.insert(grdb)
            return entry.id!
        }
    }

    @MainActor
    func seedCurrentReaderPipeline(store: ContentStore, entryId: Int64) async throws {
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
        _ = try await store.upsert(content)
        try await store.upsertCache(
            entryId: entryId,
            themeId: "default",
            html: "<html>rendered</html>",
            readerRenderVersion: ReaderPipelineVersion.readerRender
        )
    }
}
