//
//  ReaderPipelineSchemaTests.swift
//  MercuryTest
//

import Foundation
import Testing
import GRDB
@testable import Mercury

@Suite
struct ReaderPipelineSchemaTests {

    // MARK: - Migration: new columns exist after migration

    @Test

    func test_migration_contentTableHasNewColumns() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            try await fixture.database.read { db in
                let columns = try db.columns(in: Content.databaseTableName).map { $0.name }
                #expect(columns.contains("documentBaseURL"),  "content must have documentBaseURL")
                #expect(columns.contains("cleanedHtml"),       "content must have cleanedHtml")
                #expect(columns.contains("readabilityTitle"),  "content must have readabilityTitle")
                #expect(columns.contains("readabilityByline"), "content must have readabilityByline")
                #expect(columns.contains("readabilityVersion"),"content must have readabilityVersion")
                #expect(columns.contains("markdownVersion"),   "content must have markdownVersion")
            }
        }
    }

    @Test

    func test_migration_contentHTMLCacheTableHasNewColumn() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            try await fixture.database.read { db in
                let columns = try db.columns(in: ContentHTMLCache.databaseTableName).map { $0.name }
                #expect(columns.contains("readerRenderVersion"), "content_html_cache must have readerRenderVersion")
            }
        }
    }

    // MARK: - Migration: existing columns are preserved

    @Test

    func test_migration_contentTablePreservesExistingColumns() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            try await fixture.database.read { db in
                let columns = try db.columns(in: Content.databaseTableName).map { $0.name }
                for expected in ["id", "entryId", "html", "markdown", "displayMode", "createdAt"] {
                    #expect(columns.contains(expected), "content must still have column '\(expected)'")
                }
            }
        }
    }

    @Test

    func test_migration_contentHTMLCacheTablePreservesExistingColumns() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            try await fixture.database.read { db in
                let columns = try db.columns(in: ContentHTMLCache.databaseTableName).map { $0.name }
                for expected in ["entryId", "themeId", "html", "updatedAt"] {
                    #expect(columns.contains(expected), "content_html_cache must still have column '\(expected)'")
                }
            }
        }
    }

    // MARK: - Lazy upgrade: pre-existing rows can be read with nil new columns

    @Test

    func test_lazyUpgrade_oldContentRowReadsWithNilVersionFields() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let entryId = try await Self.makeTestEntry(db: fixture.database)

            // Insert a row using only the pre-migration columns.
            try await fixture.database.write { grdb in
                try grdb.execute(sql: """
                    INSERT INTO content (entryId, html, markdown, displayMode, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [entryId, "<p>test</p>", "test", "cleaned", Date()])
            }

            let content = try await fixture.database.read { grdb in
                try Content.filter(Column("entryId") == entryId).fetchOne(grdb)
            }

            #expect(content != nil)
            #expect(content?.documentBaseURL == nil,   "documentBaseURL must be nil for old rows")
            #expect(content?.cleanedHtml == nil,        "cleanedHtml must be nil for old rows")
            #expect(content?.readabilityTitle == nil,   "readabilityTitle must be nil for old rows")
            #expect(content?.readabilityByline == nil,  "readabilityByline must be nil for old rows")
            #expect(content?.readabilityVersion == nil, "readabilityVersion must be nil for old rows (version 0)")
            #expect(content?.markdownVersion == nil,    "markdownVersion must be nil for old rows (version 0)")
        }
    }

    @Test

    func test_lazyUpgrade_oldCacheRowReadsWithNilRenderVersion() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let entryId = try await Self.makeTestEntry(db: fixture.database)

            try await fixture.database.write { grdb in
                try grdb.execute(sql: """
                    INSERT INTO content_html_cache (entryId, themeId, html, updatedAt)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [entryId, "default", "<html/>", Date()])
            }

            let cache = try await fixture.database.read { grdb in
                try ContentHTMLCache
                    .filter(Column("entryId") == entryId)
                    .filter(Column("themeId") == "default")
                    .fetchOne(grdb)
            }

            #expect(cache != nil)
            #expect(cache?.readerRenderVersion == nil, "readerRenderVersion must be nil for old rows (version 0)")
        }
    }

    // MARK: - Rebuild policy: old rows produce correct action

    @Test

    func test_rebuildPolicy_oldContentAndCacheRowsProduceFetchAndRebuildFull() async throws {
        // Old content row: has neither source HTML, cleaned HTML, nor markdown.
        let state = ReaderLayerState(
            readabilityVersion: nil,
            markdownVersion: nil,
            cachedHTMLVersion: nil,
            hasCleanedHtml: false,
            hasMarkdown: false,
            hasSourceHtml: false,
            hasCachedHTML: false
        )
        #expect(ReaderRebuildPolicy.action(for: state) == .fetchAndRebuildFull)
    }

    @Test

    func test_rebuildPolicy_oldRowWithMarkdownOnlyProducesRerender() async throws {
        // Old row has markdown but no version metadata.
        // nil markdownVersion == 0, which mismatches current version 1 → should NOT serve from Markdown
        // directly. The policy must route to fetchAndRebuildFull because no upstream layer is current.
        let state = ReaderLayerState(
            readabilityVersion: nil,
            markdownVersion: nil, // version 0 — stale
            cachedHTMLVersion: nil,
            hasCleanedHtml: false,
            hasMarkdown: true,
            hasSourceHtml: false,
            hasCachedHTML: false
        )
        // nil markdownVersion → treated as 0 → mismatch → must not serve from Markdown
        #expect(
            ReaderRebuildPolicy.action(for: state) != .rerenderFromMarkdown,
            "Stale markdown (nil version) must not be used for rerender"
        )
    }

    @Test

    func test_rebuildPolicy_oldRowWithSourceHtmlProducesRerunReadability() async throws {
        // Old row has source HTML (common case for existing library).
        let state = ReaderLayerState(
            readabilityVersion: nil,
            markdownVersion: nil,
            cachedHTMLVersion: nil,
            hasCleanedHtml: false,
            hasMarkdown: false,
            hasSourceHtml: true,
            hasCachedHTML: false
        )
        #expect(
            ReaderRebuildPolicy.action(for: state) == .rerunReadabilityAndRebuild,
            "Old row with source HTML must re-run Readability locally without a network fetch"
        )
    }

    // MARK: - ContentStore.layerState integration

    @MainActor
    @Test
    func test_layerState_emptyDatabase_returnsFetchAndRebuildFull() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let store = ContentStore(db: fixture.database)
            let state = try await store.layerState(for: 99, themeId: "default")
            #expect(ReaderRebuildPolicy.action(for: state) == .fetchAndRebuildFull)
        }
    }

    @MainActor
    @Test
    func test_layerState_currentContentAndCache_returnsServeCachedHTML() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let store = ContentStore(db: fixture.database)

            // Write a fully-current content row.
            let content = Content(
                id: nil,
                entryId: entryId,
                html: "<p>source</p>",
                cleanedHtml: "<p>cleaned</p>",
                readabilityTitle: "Title",
                readabilityByline: nil,
                readabilityVersion: ReaderPipelineVersion.readability,
                markdown: "# Title\n\nparagraph",
                markdownVersion: ReaderPipelineVersion.markdown,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date()
            )
            _ = try await store.upsert(content)

            // Write a current render cache.
            try await store.upsertCache(
                entryId: entryId,
                themeId: "default",
                html: "<html/>",
                readerRenderVersion: ReaderPipelineVersion.readerRender
            )

            let state = try await store.layerState(for: entryId, themeId: "default")
            #expect(ReaderRebuildPolicy.action(for: state) == .serveCachedHTML)
        }
    }

    @MainActor
    @Test
    func test_layerState_staleCacheCurrentMarkdown_returnsRerender() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let store = ContentStore(db: fixture.database)

            let content = Content(
                id: nil,
                entryId: entryId,
                html: "<p>source</p>",
                cleanedHtml: "<p>cleaned</p>",
                readabilityTitle: "Title",
                readabilityByline: nil,
                readabilityVersion: ReaderPipelineVersion.readability,
                markdown: "# Hello",
                markdownVersion: ReaderPipelineVersion.markdown,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date()
            )
            _ = try await store.upsert(content)

            // Write a stale cache (version 0 via nil).
            try await store.upsertCache(
                entryId: entryId,
                themeId: "default",
                html: "<html/>",
                readerRenderVersion: nil
            )

            let state = try await store.layerState(for: entryId, themeId: "default")
            #expect(ReaderRebuildPolicy.action(for: state) == .rerenderFromMarkdown)
        }
    }

    // MARK: - Version constants match stored values round-trip

    @MainActor
    @Test
    func test_upsertCache_storesCurrentRenderVersion() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let store = ContentStore(db: fixture.database)
            try await store.upsertCache(
                entryId: entryId,
                themeId: "theme1",
                html: "<html/>",
                readerRenderVersion: ReaderPipelineVersion.readerRender
            )
            let cache = try await store.cachedHTML(for: entryId, themeId: "theme1")
            #expect(cache?.readerRenderVersion == ReaderPipelineVersion.readerRender)
        }
    }

    @MainActor
    @Test
    func test_upsertContent_storesCurrentVersions() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let store = ContentStore(db: fixture.database)
            let content = Content(
                id: nil,
                entryId: entryId,
                html: nil,
                cleanedHtml: "<p>x</p>",
                readabilityTitle: "T",
                readabilityByline: "B",
                readabilityVersion: ReaderPipelineVersion.readability,
                markdown: "# T",
                markdownVersion: ReaderPipelineVersion.markdown,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date()
            )
            let persisted = try await store.upsert(content)
            let loaded = try await store.content(for: entryId)
            #expect(persisted.id != nil)
            #expect(loaded?.readabilityVersion == ReaderPipelineVersion.readability)
            #expect(loaded?.markdownVersion == ReaderPipelineVersion.markdown)
            #expect(loaded?.cleanedHtml == "<p>x</p>")
            #expect(loaded?.readabilityTitle == "T")
            #expect(loaded?.readabilityByline == "B")
        }
    }

    @MainActor
    @Test
    func test_upsertContent_updatesExistingRowWhenCallerHasNoRowID() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let entryId = try await Self.makeTestEntry(db: fixture.database)
            let store = ContentStore(db: fixture.database)

            let initial = Content(
                id: nil,
                entryId: entryId,
                html: "<p>source</p>",
                cleanedHtml: nil,
                readabilityTitle: nil,
                readabilityByline: nil,
                readabilityVersion: nil,
                markdown: nil,
                markdownVersion: nil,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date()
            )
            _ = try await store.upsert(initial)

            let replacement = Content(
                id: nil,
                entryId: entryId,
                html: "<p>updated source</p>",
                cleanedHtml: "<p>updated cleaned</p>",
                readabilityTitle: "Updated",
                readabilityByline: "Byline",
                readabilityVersion: ReaderPipelineVersion.readability,
                markdown: "Updated",
                markdownVersion: ReaderPipelineVersion.markdown,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date()
            )

            let persistedReplacement = try await store.upsert(replacement)
            #expect(persistedReplacement.id != nil)

            let count = try await fixture.database.read { grdb in
                try Int.fetchOne(
                    grdb,
                    sql: "SELECT COUNT(*) FROM \(Content.databaseTableName) WHERE entryId = ?",
                    arguments: [entryId]
                ) ?? 0
            }
            #expect(count == 1, "upsert must update the existing row for the same entryId")

            let loaded = try await store.content(for: entryId)
            #expect(loaded?.html == "<p>updated source</p>")
            #expect(loaded?.cleanedHtml == "<p>updated cleaned</p>")
            #expect(loaded?.readabilityTitle == "Updated")
        }
    }
}

// MARK: - Helpers

private extension ReaderPipelineSchemaTests {
    /// Inserts a minimal feed + entry and returns the entry's auto-assigned id.
    @MainActor
    static func makeTestEntry(db: DatabaseManager) async throws -> Int64 {
        try await db.write { grdb in
            var feed = Feed(
                id: nil,
                title: "Test Feed",
                feedURL: "https://example.com/feed",
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
                url: nil,
                title: nil,
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
}
