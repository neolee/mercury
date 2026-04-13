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

    func upsert(_ content: Content) async throws -> Content {
        try await db.write { db in
            var mutableContent = content

            if mutableContent.id != nil {
                try mutableContent.save(db)
                return mutableContent
            }

            if let existingID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM \(Content.databaseTableName) WHERE entryId = ?",
                arguments: [mutableContent.entryId]
            ) {
                mutableContent.id = existingID
                try mutableContent.update(db)
            } else {
                try mutableContent.insert(db)
            }

            return mutableContent
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

    func invalidateReaderPipeline(entryId: Int64, target: ReaderPipelineTarget) async throws {
        try await db.write { db in
            let pipelineType = try Content
                .select(Column("pipelineType"))
                .filter(Column("entryId") == entryId)
                .asRequest(of: String.self)
                .fetchOne(db)
                .flatMap(ReaderPipelineType.init(rawValue:)) ?? .default

            switch target {
            case .readerHTML:
                try db.execute(
                    sql: "UPDATE \(ContentHTMLCache.databaseTableName) SET readerRenderVersion = NULL WHERE entryId = ?",
                    arguments: [entryId]
                )
            case .markdown:
                try db.execute(
                    sql: "UPDATE \(Content.databaseTableName) SET markdownVersion = NULL WHERE entryId = ?",
                    arguments: [entryId]
                )
            case .readability:
                switch pipelineType {
                case .default:
                    try db.execute(
                        sql: "UPDATE \(Content.databaseTableName) SET readabilityVersion = NULL WHERE entryId = ?",
                        arguments: [entryId]
                    )
                case .obsidian:
                    try db.execute(
                        sql: "UPDATE \(Content.databaseTableName) SET markdownVersion = NULL WHERE entryId = ?",
                        arguments: [entryId]
                    )
                }
            case .all:
                try db.execute(
                    sql: "DELETE FROM \(ContentHTMLCache.databaseTableName) WHERE entryId = ?",
                    arguments: [entryId]
                )
                try db.execute(
                    sql: "DELETE FROM \(Content.databaseTableName) WHERE entryId = ?",
                    arguments: [entryId]
                )
            }
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
