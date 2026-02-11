//
//  FeedInputValidator.swift
//  Mercury
//

import Foundation
import GRDB

struct FeedInputValidator {
    let database: DatabaseManager

    func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedURLString(_ urlString: String?) -> String? {
        guard let urlString else { return nil }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func validateFeedURL(_ urlString: String) throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw FeedEditError.invalidURL }
        guard let url = URL(string: trimmed), url.scheme != nil else { throw FeedEditError.invalidURL }
        return trimmed
    }

    func feedExists(withURL feedURL: String, excludingFeedId: Int64? = nil) async throws -> Bool {
        try await database.read { db in
            var request = Feed.filter(Column("feedURL") == feedURL)
            if let excludingFeedId {
                request = request.filter(Column("id") != excludingFeedId)
            }
            return try request.fetchOne(db) != nil
        }
    }

    static func isDuplicateFeedURLError(_ error: Error) -> Bool {
        if let dbError = error as? DatabaseError {
            if dbError.resultCode == .SQLITE_CONSTRAINT || dbError.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                let message = (dbError.message ?? "").lowercased()
                if message.contains("feed.feedurl") || message.contains("feedurl") {
                    return true
                }
            }
        }
        return false
    }
}
