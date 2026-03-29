import Foundation
import GRDB

struct SingleEntryDigestProjection: Decodable, FetchableRecord, Sendable {
    let entryId: Int64
    let articleTitle: String?
    let articleURL: String?
    let entryAuthor: String?
    let readabilityByline: String?
    let feedTitle: String?
}

extension AppModel {
    func loadSingleEntryDigestProjection(entryId: Int64) async throws -> SingleEntryDigestProjection? {
        try await database.read { db in
            try SingleEntryDigestProjection.fetchOne(
                db,
                sql: """
                SELECT
                    e.id AS entryId,
                    e.title AS articleTitle,
                    e.url AS articleURL,
                    e.author AS entryAuthor,
                    c.readabilityByline AS readabilityByline,
                    f.title AS feedTitle
                FROM \(Entry.databaseTableName) e
                LEFT JOIN \(Content.databaseTableName) c ON c.entryId = e.id
                LEFT JOIN \(Feed.databaseTableName) f ON f.id = e.feedId
                WHERE e.id = ?
                LIMIT 1
                """,
                arguments: [entryId]
            )
        }
    }
}
