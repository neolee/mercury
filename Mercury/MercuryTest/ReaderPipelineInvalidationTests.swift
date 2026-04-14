//
//  ReaderPipelineInvalidationTests.swift
//  MercuryTest
//

import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Reader Pipeline Invalidation")
@MainActor
struct ReaderPipelineInvalidationTests {

    @Test("Invalidate reader HTML marks all theme caches stale for entry only")
    @MainActor
    func invalidateReaderHTMLMarksAllThemeCachesStaleForEntryOnly() async throws {
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

            #expect(targetDefaultCache?.readerRenderVersion == nil)
            #expect(targetAlternateCache?.readerRenderVersion == nil)
            #expect(otherEntryCache?.readerRenderVersion == ReaderPipelineVersion.readerRender)
            #expect(targetContent?.readabilityVersion == ReaderPipelineVersion.readability)
            #expect(targetContent?.markdownVersion == ReaderPipelineVersion.markdown)
        }
    }

    @Test("Invalidate Markdown clears Markdown version only")
    @MainActor
    func invalidateMarkdownClearsMarkdownVersionOnly() async throws {
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

            #expect(targetContent?.markdownVersion == nil)
            #expect(targetContent?.readabilityVersion == ReaderPipelineVersion.readability)
            #expect(targetContent?.markdown == "# Title\n\nBody")
            #expect(targetCache?.readerRenderVersion == ReaderPipelineVersion.readerRender)
            #expect(otherContent?.markdownVersion == ReaderPipelineVersion.markdown)
        }
    }

    @Test("Invalidate readability clears readability version only")
    @MainActor
    func invalidateReadabilityClearsReadabilityVersionOnly() async throws {
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

            #expect(targetContent?.readabilityVersion == nil)
            #expect(targetContent?.markdownVersion == ReaderPipelineVersion.markdown)
            #expect(targetContent?.cleanedHtml == "<p>Body</p>")
            #expect(targetCache?.readerRenderVersion == ReaderPipelineVersion.readerRender)
            #expect(otherContent?.readabilityVersion == ReaderPipelineVersion.readability)
        }
    }

    @Test("Invalidate readability target maps to upstream rebuild for Obsidian pipeline")
    @MainActor
    func invalidateReadabilityMapsToObsidianUpstreamRebuild() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let store = ContentStore(db: fixture.database)
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let otherEntryId = try await Self.makeTestEntry(db: fixture.database)

            try await seedCurrentObsidianReaderPipeline(store: store, entryId: entryId)
            try await seedCurrentObsidianReaderPipeline(store: store, entryId: otherEntryId)

            try await store.invalidateReaderPipeline(entryId: entryId, target: .readability)

            let targetContent = try await store.content(for: entryId)
            let otherContent = try await store.content(for: otherEntryId)
            let targetCache = try await store.cachedHTML(for: entryId, themeId: "default")

            #expect(targetContent?.pipelineType == ReaderPipelineType.obsidian.rawValue)
            #expect(targetContent?.markdownVersion == nil)
            #expect(targetContent?.resolvedIntermediateContent == "https://publish.example.com/article.md")
            #expect(targetContent?.readabilityVersion == nil)
            #expect(targetCache?.readerRenderVersion == ReaderPipelineVersion.readerRender)
            #expect(otherContent?.markdownVersion == ReaderPipelineVersion.markdown)
        }
    }

    @Test("Invalidate all deletes content and all caches for entry only")
    @MainActor
    func invalidateAllDeletesContentAndAllCachesForEntryOnly() async throws {
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

            #expect(targetContent == nil)
            #expect(targetDefaultCache == nil)
            #expect(targetAlternateCache == nil)
            #expect(otherContent != nil)
            #expect(otherCache != nil)
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

    @MainActor
    func seedCurrentObsidianReaderPipeline(store: ContentStore, entryId: Int64) async throws {
        let content = Content(
            id: nil,
            entryId: entryId,
            html: "<html>shell</html>",
            cleanedHtml: nil,
            readabilityTitle: nil,
            readabilityByline: nil,
            readabilityVersion: nil,
            markdown: "# Title\n\nBody",
            markdownVersion: ReaderPipelineVersion.markdown,
            displayMode: ContentDisplayMode.cleaned.rawValue,
            createdAt: Date(),
            pipelineType: ReaderPipelineType.obsidian.rawValue,
            resolvedIntermediateContent: "https://publish.example.com/article.md"
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
