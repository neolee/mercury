import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Entry Note Store")
struct EntryNoteStoreTests {
    @Test("Upsert creates, updates, and deletes note row")
    @MainActor
    func upsertAndDeleteNote() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: EntryNoteTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entryId = try await seedEntry(using: appModel)

            let first = try await appModel.upsertEntryNote(entryId: entryId, markdownText: "First note")
            #expect(first.entryId == entryId)
            #expect(first.markdownText == "First note")

            let loadedFirst = try await appModel.loadEntryNote(entryId: entryId)
            #expect(loadedFirst?.markdownText == "First note")

            let second = try await appModel.upsertEntryNote(entryId: entryId, markdownText: "Updated note")
            #expect(second.entryId == entryId)
            #expect(second.markdownText == "Updated note")
            #expect(second.updatedAt >= first.updatedAt)

            let noteCount = try await appModel.database.read { db in
                try EntryNote.fetchCount(db)
            }
            #expect(noteCount == 1)

            let deleted = try await appModel.deleteEntryNote(entryId: entryId)
            #expect(deleted == true)
            #expect(try await appModel.loadEntryNote(entryId: entryId) == nil)
        }
    }

    private func seedEntry(using appModel: AppModel) async throws -> Int64 {
        try await appModel.database.write { db in
            var feed = Feed(
                id: nil,
                title: "Test Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw EntryNoteStoreTestError.missingFeedID
            }

            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "entry-\(UUID().uuidString)",
                url: "https://example.com/article",
                title: "Entry",
                author: "Author",
                publishedAt: Date(),
                summary: nil,
                isRead: false,
                createdAt: Date()
            )
            try entry.insert(db)
            guard let entryId = entry.id else {
                throw EntryNoteStoreTestError.missingEntryID
            }
            return entryId
        }
    }
}

private enum EntryNoteStoreTestError: Error {
    case missingFeedID
    case missingEntryID
}

private final class EntryNoteTestCredentialStore: CredentialStore, @unchecked Sendable {
    func save(secret: String, for ref: String) throws {}
    func readSecret(for ref: String) throws -> String { "" }
    func deleteSecret(for ref: String) throws {}
}
