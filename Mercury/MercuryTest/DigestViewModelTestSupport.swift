import Foundation
import GRDB
@testable import Mercury

@MainActor
func seedDigestEntry(using appModel: AppModel) async throws -> Entry {
    try await appModel.database.write { db in
        var feed = Feed(
            id: nil,
            title: "Digest Feed",
            feedURL: "https://example.com/feed-\(UUID().uuidString)",
            siteURL: "https://example.com",
            lastFetchedAt: nil,
            createdAt: Date()
        )
        try feed.insert(db)
        guard let feedId = feed.id else {
            throw DigestViewModelTestError.missingFeedID
        }

        var entry = Entry(
            id: nil,
            feedId: feedId,
            guid: "digest-\(UUID().uuidString)",
            url: "https://example.com/article",
            title: "Digest Entry",
            author: "Neo",
            publishedAt: Date(),
            summary: "Entry summary",
            isRead: false,
            createdAt: Date()
        )
        try entry.insert(db)
        return entry
    }
}

func requiredEntryID(_ entry: Entry) throws -> Int64 {
    guard let entryId = entry.id else {
        throw DigestViewModelTestError.missingEntryID
    }
    return entryId
}

enum DigestViewModelTestError: Error {
    case missingFeedID
    case missingEntryID
}

final class DigestViewModelTestCredentialStore: CredentialStore, @unchecked Sendable {
    func save(secret: String, for ref: String) throws {}
    func readSecret(for ref: String) throws -> String { "" }
    func deleteSecret(for ref: String) throws {}
}
