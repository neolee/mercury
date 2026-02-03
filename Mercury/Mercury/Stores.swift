//
//  Stores.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Combine
import Foundation
import GRDB

@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var feeds: [Feed] = []

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func loadAll() async {
        do {
            let values = try await db.read { db in
                try Feed.order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
            }
            feeds = values
        } catch {
            feeds = []
        }
    }

    func upsert(_ feed: Feed) async throws {
        try await db.write { db in
            var mutableFeed = feed
            try mutableFeed.save(db)
        }
        await loadAll()
    }

    func delete(_ feed: Feed) async throws {
        try await db.write { db in
            _ = try feed.delete(db)
        }
        await loadAll()
    }
}

@MainActor
final class EntryStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func loadAll(for feedId: Int64?) async {
        do {
            let values = try await db.read { db in
                var request = Entry.order(Column("publishedAt").desc, Column("createdAt").desc)
                if let feedId {
                    request = request.filter(Column("feedId") == feedId)
                }
                return try request.fetchAll(db)
            }
            entries = values
        } catch {
            entries = []
        }
    }

    func markRead(entryId: Int64, isRead: Bool) async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE entry SET isRead = ? WHERE id = ?",
                arguments: [isRead, entryId]
            )
        }
    }
}

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
}
