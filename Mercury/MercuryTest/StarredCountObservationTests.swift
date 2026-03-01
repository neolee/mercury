import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Starred Count Observation")
struct StarredCountObservationTests {
    @Test("totalStarredCount updates after database changes")
    @MainActor
    func totalStarredCountTracksDatabase() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: StarredCountTestCredentialStore()
        )

        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            appModel.totalStarredCount == 0
        }

        let (feedId, entryId) = try await appModel.database.write { db in
            var feed = Feed(
                id: nil,
                title: "Starred Count Feed",
                feedURL: "https://example.com/starred-count-\(UUID().uuidString)",
                siteURL: "https://example.com",
                unreadCount: 0,
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw TestError.missingFeedID
            }

            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "starred-count-\(UUID().uuidString)",
                url: "https://example.com/starred-count",
                title: "Starred Count Entry",
                author: nil,
                publishedAt: Date(),
                summary: "count",
                isRead: false,
                isStarred: true,
                createdAt: Date()
            )
            try entry.insert(db)
            guard let entryId = entry.id else {
                throw TestError.missingEntryID
            }
            return (feedId, entryId)
        }

        _ = feedId
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            appModel.totalStarredCount == 1
        }

        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            appModel.starredUnreadCount == 1
        }

        try await appModel.database.write { db in
            _ = try Entry
                .filter(Column("id") == entryId)
                .updateAll(db, Column("isRead").set(to: true))
        }

        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            appModel.totalStarredCount == 1 && appModel.starredUnreadCount == 0
        }

        try await appModel.database.write { db in
            _ = try Entry
                .filter(Column("id") == entryId)
                .updateAll(db, Column("isStarred").set(to: false))
        }

        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            appModel.totalStarredCount == 0
        }
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-starred-count-tests-\(UUID().uuidString).sqlite")
            .path
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        predicate: @escaping () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while predicate() == false {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - start > timeoutNanoseconds {
                throw TestError.timeout
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private enum TestError: Error {
        case missingFeedID
        case missingEntryID
        case timeout
    }
}

private final class StarredCountTestCredentialStore: CredentialStore, @unchecked Sendable {
    func save(secret: String, for ref: String) throws {
    }

    func readSecret(for ref: String) throws -> String {
        throw CredentialStoreError.itemNotFound
    }

    func deleteSecret(for ref: String) throws {
    }
}
