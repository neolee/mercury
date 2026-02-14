//
//  DatabaseManager.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation
import GRDB

final class DatabaseManager {
    let dbQueue: DatabaseQueue
    private let queue: DispatchQueue

    init() throws {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = appSupport.appendingPathComponent("Mercury", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let dbURL = folder.appendingPathComponent("mercury.sqlite")
        dbQueue = try DatabaseQueue(path: dbURL.path)
        queue = DispatchQueue(label: "Mercury.Database")

        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createFeed") { db in
            try db.create(table: Feed.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text)
                t.column("feedURL", .text).notNull()
                t.column("siteURL", .text)
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("lastFetchedAt", .datetime)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_feed_feedURL", on: Feed.databaseTableName, columns: ["feedURL"], unique: true)
        }

        migrator.registerMigration("createEntry") { db in
            try db.create(table: Entry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("feedId", .integer).notNull().indexed().references(Feed.databaseTableName, onDelete: .cascade)
                t.column("guid", .text)
                t.column("url", .text)
                t.column("title", .text)
                t.column("author", .text)
                t.column("publishedAt", .datetime)
                t.column("summary", .text)
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_entry_feed_guid", on: Entry.databaseTableName, columns: ["feedId", "guid"], unique: true)
            try db.create(index: "idx_entry_feed_url", on: Entry.databaseTableName, columns: ["feedId", "url"], unique: true)
        }

        migrator.registerMigration("createContent") { db in
            try db.create(table: Content.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entryId", .integer).notNull().indexed().references(Entry.databaseTableName, onDelete: .cascade)
                t.column("html", .text)
                t.column("markdown", .text)
                t.column("displayMode", .text).notNull().defaults(to: ContentDisplayMode.web.rawValue)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_content_entry", on: Content.databaseTableName, columns: ["entryId"], unique: true)
        }

        migrator.registerMigration("createContentHTMLCache") { db in
            try db.create(table: ContentHTMLCache.databaseTableName) { t in
                t.column("entryId", .integer).notNull().references(Entry.databaseTableName, onDelete: .cascade)
                t.column("themeId", .text).notNull()
                t.column("html", .text).notNull()
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
                t.primaryKey(["themeId", "entryId"])
            }
        }

        migrator.registerMigration("addEntryListIndexes") { db in
            try db.create(index: "idx_entry_published_created", on: Entry.databaseTableName, columns: ["publishedAt", "createdAt"])
            try db.create(index: "idx_entry_feed_published_created", on: Entry.databaseTableName, columns: ["feedId", "publishedAt", "createdAt"])
            try db.create(index: "idx_entry_isRead_published_created", on: Entry.databaseTableName, columns: ["isRead", "publishedAt", "createdAt"])
        }

        return migrator
    }

    func read<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try self.dbQueue.read(block)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func write<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try self.dbQueue.write(block)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
