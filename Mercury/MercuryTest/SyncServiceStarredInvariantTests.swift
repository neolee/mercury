import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("SyncService Starred Invariant")
struct SyncServiceStarredInvariantTests {
    @Test("Conflict-ignored sync insert preserves existing isStarred")
    @MainActor
    func conflictIgnoredInsertKeepsExistingStarState() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let manager = try DatabaseManager(path: dbPath)

        let (feedId, existingEntryId) = try await manager.write { db in
            var feed = Feed(
                id: nil,
                title: "Invariant Feed",
                feedURL: "https://example.com/invariant-feed",
                siteURL: "https://example.com",
                unreadCount: 0,
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw TestError.missingFeedID
            }

            var existingEntry = Entry(
                id: nil,
                feedId: feedId,
                guid: "guid-001",
                url: "https://example.com/article/1",
                title: "Existing Starred Entry",
                author: nil,
                publishedAt: Date(),
                summary: "existing",
                isRead: false,
                isStarred: true,
                createdAt: Date()
            )
            try existingEntry.insert(db)
            guard let entryId = existingEntry.id else {
                throw TestError.missingEntryID
            }

            return (feedId, entryId)
        }

        try await manager.write { db in
            var incomingEntry = Entry(
                id: nil,
                feedId: feedId,
                guid: "guid-001",
                url: "https://example.com/article/1",
                title: "Incoming Sync Entry",
                author: nil,
                publishedAt: Date().addingTimeInterval(60),
                summary: "incoming",
                isRead: false,
                isStarred: false,
                createdAt: Date().addingTimeInterval(60)
            )
            try incomingEntry.insert(db, onConflict: .ignore)
        }

        let snapshot = try await manager.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM entry WHERE feedId = ?",
                arguments: [feedId]
            ) ?? 0
            let row = try Row.fetchOne(
                db,
                sql: "SELECT id, title, isStarred FROM entry WHERE feedId = ? AND guid = ? LIMIT 1",
                arguments: [feedId, "guid-001"]
            )
            return (count, row)
        }

        #expect(snapshot.0 == 1)
        #expect((snapshot.1?["id"] as Int64?) == existingEntryId)
        #expect((snapshot.1?["title"] as String?) == "Existing Starred Entry")
        #expect((snapshot.1?["isStarred"] as Bool?) == true)
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-sync-starred-invariant-tests-\(UUID().uuidString).sqlite")
            .path
    }

    private enum TestError: Error {
        case missingFeedID
        case missingEntryID
    }
}
