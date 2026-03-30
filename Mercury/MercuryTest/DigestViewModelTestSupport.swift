import Foundation
import GRDB
@testable import Mercury

@MainActor
func seedDigestEntry(using appModel: AppModel) async throws -> Entry {
    let entries = try await seedDigestEntries(using: appModel, count: 1)
    guard let entry = entries.first else {
        throw DigestViewModelTestError.missingEntryID
    }
    return entry
}

@MainActor
func seedDigestEntries(using appModel: AppModel, count: Int) async throws -> [Entry] {
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

        return try (0..<count).map { index in
            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "digest-\(UUID().uuidString)",
                url: "https://example.com/article-\(index + 1)",
                title: count == 1 ? "Digest Entry" : "Digest Entry \(index + 1)",
                author: "Neo",
                publishedAt: Date().addingTimeInterval(Double(index)),
                summary: "Entry summary \(index + 1)",
                isRead: false,
                createdAt: Date().addingTimeInterval(Double(index))
            )
            try entry.insert(db)
            return entry
        }
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
