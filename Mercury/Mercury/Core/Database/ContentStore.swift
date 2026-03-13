//
//  ContentStore.swift
//  Mercury
//

import Combine
import Foundation
import GRDB

@MainActor
final class ContentStore: ObservableObject {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func content(for entryId: Int64) async throws -> Content? {
        try await db.read { db in
            try Content.filter(Column("entryId") == entryId).fetchOne(db)
        }
    }

    func upsert(_ content: Content) async throws {
        try await db.write { db in
            var mutableContent = content
            try mutableContent.save(db)
        }
    }

    func cachedHTML(for entryId: Int64, themeId: String) async throws -> ContentHTMLCache? {
        try await db.read { db in
            try ContentHTMLCache
                .filter(Column("entryId") == entryId)
                .filter(Column("themeId") == themeId)
                .fetchOne(db)
        }
    }

    func upsertCache(entryId: Int64, themeId: String, html: String, readerRenderVersion: Int? = nil) async throws {
        let cache = ContentHTMLCache(
            entryId: entryId,
            themeId: themeId,
            html: html,
            readerRenderVersion: readerRenderVersion,
            updatedAt: Date()
        )
        try await db.write { db in
            var mutableCache = cache
            try mutableCache.save(db)
        }
    }

    /// Builds a `ReaderLayerState` by reading both the `content` row and the
    /// `content_html_cache` row for the given entry and theme.
    func layerState(for entryId: Int64, themeId: String) async throws -> ReaderLayerState {
        let content = try await db.read { db in
            try Content.filter(Column("entryId") == entryId).fetchOne(db)
        }
        let cache = try await db.read { db in
            try ContentHTMLCache
                .filter(Column("entryId") == entryId)
                .filter(Column("themeId") == themeId)
                .fetchOne(db)
        }
        return ReaderLayerState(
            readabilityVersion: content?.readabilityVersion,
            markdownVersion: content?.markdownVersion,
            cachedHTMLVersion: cache?.readerRenderVersion,
            hasCleanedHtml: content?.cleanedHtml?.isEmpty == false,
            hasMarkdown: content?.markdown?.isEmpty == false,
            hasSourceHtml: content?.html?.isEmpty == false,
            hasCachedHTML: cache != nil
        )
    }
}

